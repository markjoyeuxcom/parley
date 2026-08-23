import AppKit
import Darwin
import Foundation
import ParleyCore
import ParleyTerminal
import SwiftTerm

private struct SoakReport: Codable {
    let schemaVersion: Int
    let durationSeconds: Int
    let outputPaneCount: Int
    let workspaceCount: Int
    let workspaceSwitches: Int
    let terminalReattachments: Int
    let paneProcessesPreserved: Bool
    let metalRendererEnabled: Bool
    let relayOperations: Int
    let retainedHandoffs: Int
    let retainedJournalHandoffs: Int
    let memory: MemoryPlateauAssessment
    let tmuxMemory: MemoryPlateauAssessment

    var passed: Bool {
        memory.verdict == .passed
            && tmuxMemory.verdict == .passed
            && outputPaneCount == 7
            && workspaceCount == 4
            && workspaceSwitches >= 50
            && terminalReattachments == 1
            && paneProcessesPreserved
            && metalRendererEnabled
            && relayOperations >= 1_000
            && retainedHandoffs == 500
            && retainedJournalHandoffs == 500
    }
}

private enum SoakFailure: LocalizedError {
    case command(String)
    case missingPane
    case terminalMemoryUnavailable
    case failed(SoakReport)

    var errorDescription: String? {
        switch self {
        case let .command(detail): detail
        case .missingPane: "The isolated tmux soak session did not expose its pane."
        case .terminalMemoryUnavailable: "The soak runner could not read its resident memory."
        case let .failed(report):
            "The native soak gate failed: app-memory=\(report.memory.verdict.rawValue), tmux-memory=\(report.tmuxMemory.verdict.rawValue), panes=\(report.outputPaneCount), workspaces=\(report.workspaceCount), switches=\(report.workspaceSwitches), reattachments=\(report.terminalReattachments), preserved=\(report.paneProcessesPreserved), metal=\(report.metalRendererEnabled), relays=\(report.relayOperations)."
        }
    }
}

private final class RelayLoad {
    let broker: RelayBroker
    let journal: RelayHandoffJournal
    private let panes: [TmuxPane]
    private let tokens: [String]
    private(set) var operations = 0

    init(directory: URL) throws {
        panes = [
            Self.pane(id: "%fixture-claude", kind: .claude),
            Self.pane(id: "%fixture-codex", kind: .codex),
            Self.pane(id: "%fixture-agy", kind: .agy),
            Self.pane(id: "%fixture-copilot", kind: .copilot),
        ]
        let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
        tokens = try panes.map { try credentials.token(for: $0.id) }
        journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"))
        let paneSnapshot = panes
        broker = RelayBroker(
            credentials: credentials,
            panes: { paneSnapshot },
            paste: { _, _ in },
            submit: { _, _ in },
            handoffJournal: journal
        )
    }

    func runBatch(count: Int) throws {
        for _ in 0..<count {
            let senderIndex = operations % panes.count
            let targetIndex = (senderIndex + 1) % panes.count
            let response = broker.handle(
                token: tokens[senderIndex],
                target: panes[targetIndex].id,
                text: "Deterministic soak handoff \(operations)",
                idempotencyKey: String(format: "soak-%08d", operations)
            )
            guard response.status == 200, response.body.state == .completed else {
                throw SoakFailure.command(response.body.error ?? "A deterministic relay did not complete.")
            }
            operations += 1
        }
    }

    private static func pane(id: String, kind: PaneKind) -> TmuxPane {
        TmuxPane(
            id: id,
            kind: kind,
            customName: nil,
            terminalTitle: "",
            cwd: "/",
            currentCommand: "fixture",
            isActive: false,
            windowID: "@fixture",
            returnToPaneID: nil,
            relayEnabled: true,
            protocolVersion: AgentProtocol.version,
            workspaceName: nil,
            bracketedPasteActive: true,
            isStarted: true
        )
    }
}

@main
private struct ParleySoak {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--output-fixture") {
            runOutputFixture()
            return
        }

        do {
            let report = try runSoak()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            guard report.passed else { throw SoakFailure.failed(report) }
        } catch {
            FileHandle.standardError.write(Data("Native soak failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func runSoak() throws -> SoakReport {
        let duration = max(24, Int(ProcessInfo.processInfo.environment["PARLEY_SOAK_SECONDS"] ?? "") ?? 36)
        let root = FileManager.default.temporaryDirectory
            // Unix-domain socket paths are capped at 104 bytes on macOS. Keep
            // the isolated root intentionally short even when TMPDIR is long.
            .appendingPathComponent("psoak-\(UUID().uuidString.lowercased().prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionName = "parley-soak-\(UUID().uuidString.lowercased().prefix(8))"
        let controller = try TmuxController(
            applicationDirectory: root,
            sessionName: sessionName
        )
        let runner = ProcessCommandRunner(timeout: 15)
        defer {
            _ = try? tmux(
                controller,
                runner: runner,
                arguments: ["kill-server"],
                allowFailure: true
            )
        }
        try controller.bootstrap(cwd: root.path)

        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let outputPanes = try configureOutputPanes(
            controller: controller,
            runner: runner,
            executable: executable,
            duration: duration + 15,
            cwd: root.path
        )
        let workspaces = try controller.listWorkspaces()
        guard let firstWorkspace = workspaces.first else { throw SoakFailure.missingPane }
        try controller.selectWorkspace(firstWorkspace.id)

        let originalProcesses = try paneProcesses(controller, runner: runner)
        let tmuxPID = try tmuxServerPID(controller, runner: runner)
        let relayLoad = try RelayLoad(directory: root.appendingPathComponent("relay-load", isDirectory: true))
        try relayLoad.runBatch(count: 600)

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 980, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Parley quota-free soak"
        window.isReleasedWhenClosed = false
        window.orderBack(nil)

        var terminal = try attachTerminal(controller: controller, window: window)
        var metalEnabled = terminal.isUsingMetalRenderer
        var samples: [UInt64] = []
        var tmuxSamples: [UInt64] = []
        var workspaceSwitches = 0
        var terminalReattachments = 0
        var nextWorkspace = 0
        var nextSample = Date()
        var nextSwitch = Date()
        var nextRelay = Date()
        let started = Date()
        let reattachAt = TimeInterval(8)
        var didReattach = false

        while Date().timeIntervalSince(started) < TimeInterval(duration) {
            try autoreleasepool {
                let now = Date()
                if now >= nextSwitch {
                    nextWorkspace = (nextWorkspace + 1) % workspaces.count
                    try controller.selectWorkspace(workspaces[nextWorkspace].id)
                    workspaceSwitches += 1
                    nextSwitch = now.addingTimeInterval(0.2)
                }
                if now >= nextRelay {
                    try relayLoad.runBatch(count: 10)
                    nextRelay = now.addingTimeInterval(0.1)
                }
                if !didReattach, now.timeIntervalSince(started) >= reattachAt {
                    terminal.terminate()
                    terminal.removeFromSuperview()
                    pumpRunLoop(for: 0.25)
                    terminal = try attachTerminal(controller: controller, window: window)
                    metalEnabled = metalEnabled && terminal.isUsingMetalRenderer
                    terminalReattachments += 1
                    didReattach = true
                }
                if now >= nextSample {
                    guard let resident = DiagnosticsProcessMemory.residentBytes(
                        pid: ProcessInfo.processInfo.processIdentifier
                    ), let tmuxResident = DiagnosticsProcessMemory.residentBytes(pid: tmuxPID) else {
                        throw SoakFailure.terminalMemoryUnavailable
                    }
                    samples.append(resident)
                    tmuxSamples.append(tmuxResident)
                    nextSample = now.addingTimeInterval(1)
                }
                pumpRunLoop(for: 0.025)
            }
        }

        let finalProcesses = try paneProcesses(controller, runner: runner)
        terminal.terminate()
        terminal.removeFromSuperview()
        window.close()
        pumpRunLoop(for: 0.2)

        // Every fixture writes beyond tmux's 10,000-line history limit during
        // its first 15 seconds. Exclude at least 18 samples so both tmux history
        // and renderer caches have reached their bounded steady-state shape.
        let warmupSamples = min(max(18, samples.count / 3), max(0, samples.count - 6))
        let assessment = MemoryPlateauAssessment.evaluate(
            samples: samples,
            warmupSamples: warmupSamples,
            absoluteAllowanceBytes: 16 * 1_024 * 1_024,
            relativeAllowance: 0.10
        )
        let tmuxAssessment = MemoryPlateauAssessment.evaluate(
            samples: tmuxSamples,
            warmupSamples: warmupSamples,
            absoluteAllowanceBytes: 16 * 1_024 * 1_024,
            relativeAllowance: 0.10
        )
        return SoakReport(
            schemaVersion: 1,
            durationSeconds: duration,
            outputPaneCount: outputPanes.count,
            workspaceCount: workspaces.count,
            workspaceSwitches: workspaceSwitches,
            terminalReattachments: terminalReattachments,
            paneProcessesPreserved: originalProcesses == finalProcesses,
            metalRendererEnabled: metalEnabled,
            relayOperations: relayLoad.operations,
            retainedHandoffs: relayLoad.broker.handoffs().count,
            retainedJournalHandoffs: relayLoad.journal.handoffs().count,
            memory: assessment,
            tmuxMemory: tmuxAssessment
        )
    }

    @MainActor
    private static func attachTerminal(
        controller: TmuxController,
        window: NSWindow
    ) throws -> LocalProcessTerminalView {
        guard let content = window.contentView else {
            throw SoakFailure.command("The soak window has no content view.")
        }
        let terminal = LocalProcessTerminalView(frame: content.bounds)
        ParleyTerminalConfiguration.apply(to: terminal)
        content.addSubview(terminal)
        terminal.startProcess(
            executable: controller.tmuxExecutable.path,
            args: controller.attachArguments(),
            environment: terminalEnvironment(controller.environment),
            currentDirectory: controller.applicationDirectory.path
        )
        pumpRunLoop(for: 0.25)
        try ParleyTerminalConfiguration.enablePreferredRenderer(on: terminal)
        pumpRunLoop(for: 0.1)
        return terminal
    }

    private static func configureOutputPanes(
        controller: TmuxController,
        runner: ProcessCommandRunner,
        executable: URL,
        duration: Int,
        cwd: String
    ) throws -> [String] {
        guard let initial = try controller.listPanes().first,
              let initialWorkspace = try controller.listWorkspaces().first else {
            throw SoakFailure.missingPane
        }
        var panes = [initial.id]
        try configureFixture(
            initial.id,
            kind: .claude,
            stream: 0,
            controller: controller,
            runner: runner,
            executable: executable,
            duration: duration,
            cwd: cwd
        )
        for (offset, kind) in [PaneKind.codex, .agy, .copilot].enumerated() {
            let output = try tmux(
                controller,
                runner: runner,
                arguments: [
                    "split-window", "-d", "-P", "-F", "#{pane_id}",
                    offset.isMultiple(of: 2) ? "-h" : "-v",
                    "-t", initial.id, "-c", cwd,
                    executable.path, "--output-fixture", String(duration), String(offset + 1),
                ]
            )
            let paneID = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneID.isEmpty else { throw SoakFailure.missingPane }
            panes.append(paneID)
            try setFixtureMetadata(paneID, kind: kind, controller: controller, runner: runner)
        }
        _ = try tmux(
            controller,
            runner: runner,
            arguments: ["select-layout", "-t", initialWorkspace.id, "tiled"]
        )

        for index in 1...3 {
            let workspace = try controller.createWorkspace(folder: cwd, name: "Soak \(index + 1)")
            guard let pane = try controller.listPanes().first(where: { $0.windowID == workspace.id }) else {
                throw SoakFailure.missingPane
            }
            try configureFixture(
                pane.id,
                kind: .shell,
                stream: index + 3,
                controller: controller,
                runner: runner,
                executable: executable,
                duration: duration,
                cwd: cwd
            )
            panes.append(pane.id)
        }
        return panes
    }

    private static func configureFixture(
        _ paneID: String,
        kind: PaneKind,
        stream: Int,
        controller: TmuxController,
        runner: ProcessCommandRunner,
        executable: URL,
        duration: Int,
        cwd: String
    ) throws {
        _ = try tmux(
            controller,
            runner: runner,
            arguments: [
                "respawn-pane", "-k", "-t", paneID, "-c", cwd,
                executable.path, "--output-fixture", String(duration), String(stream),
            ]
        )
        try setFixtureMetadata(paneID, kind: kind, controller: controller, runner: runner)
    }

    private static func setFixtureMetadata(
        _ paneID: String,
        kind: PaneKind,
        controller: TmuxController,
        runner: ProcessCommandRunner
    ) throws {
        for (name, value) in [
            ("@parley-kind", kind.rawValue),
            ("@parley-name", "Soak \(kind.label)"),
            ("@parley-started", "1"),
            ("@parley-protocol", kind.isAgent ? AgentProtocol.version : ""),
        ] {
            let arguments = value.isEmpty
                ? ["set-option", "-p", "-u", "-t", paneID, name]
                : ["set-option", "-p", "-t", paneID, name, value]
            _ = try tmux(controller, runner: runner, arguments: arguments, allowFailure: value.isEmpty)
        }
    }

    private static func paneProcesses(
        _ controller: TmuxController,
        runner: ProcessCommandRunner
    ) throws -> [String: Int32] {
        let output = try tmux(
            controller,
            runner: runner,
            arguments: [
                "list-panes", "-s", "-t", "=\(controller.sessionName)",
                "-F", "#{pane_id}\u{1f}#{pane_pid}",
            ]
        )
        return Dictionary(uniqueKeysWithValues: output.stdoutText.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 2, let pid = Int32(fields[1]) else { return nil }
            return (String(fields[0]), pid)
        })
    }

    private static func tmuxServerPID(
        _ controller: TmuxController,
        runner: ProcessCommandRunner
    ) throws -> Int32 {
        let output = try tmux(
            controller,
            runner: runner,
            arguments: ["display-message", "-p", "#{pid}"]
        )
        guard let pid = Int32(output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SoakFailure.command("tmux did not report its isolated server pid")
        }
        return pid
    }

    @discardableResult
    private static func tmux(
        _ controller: TmuxController,
        runner: ProcessCommandRunner,
        arguments: [String],
        allowFailure: Bool = false
    ) throws -> CommandOutput {
        let output = try runner.run(
            executable: controller.tmuxExecutable,
            arguments: ["-S", controller.socketPath.path, "-f", controller.configPath.path] + arguments,
            environment: controller.environment,
            input: nil
        )
        if output.status != 0, !allowFailure {
            let detail = (output.stdoutText + "\n" + output.stderrText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SoakFailure.command(detail.isEmpty ? "tmux \(arguments.first ?? "command") failed" : detail)
        }
        return output
    }

    private static func terminalEnvironment(_ source: [String: String]) -> [String] {
        var environment = source.filter { $0.key != "TMUX" && $0.key != "TMUX_PANE" }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    @MainActor
    private static func pumpRunLoop(for interval: TimeInterval) {
        let end = Date().addingTimeInterval(interval)
        while Date() < end {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01)))
            }
        }
    }

    private static func runOutputFixture() {
        signal(SIGPIPE, SIG_IGN)
        let markerIndex = CommandLine.arguments.firstIndex(of: "--output-fixture") ?? 0
        let duration = CommandLine.arguments.indices.contains(markerIndex + 1)
            ? (Int(CommandLine.arguments[markerIndex + 1]) ?? 45)
            : 45
        let stream = CommandLine.arguments.indices.contains(markerIndex + 2)
            ? (Int(CommandLine.arguments[markerIndex + 2]) ?? 0)
            : 0
        let started = Date()
        var frame = 0
        var alternateScreen = false
        let glyphs = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        while Date().timeIntervalSince(started) < TimeInterval(duration) {
            var output = ""
            if Date().timeIntervalSince(started) < 15 {
                for row in 0..<40 {
                    let glyph = glyphs[(frame + row + stream) % glyphs.count]
                    output += "stream=\(stream) frame=\(frame) row=\(row) "
                    output += String(repeating: glyph, count: 96)
                    output += "\r\n"
                }
            } else {
                if !alternateScreen {
                    output += "\u{1b}[?1049h\u{1b}[?25l"
                    alternateScreen = true
                }
                output += "\u{1b}[H"
                for row in 0..<40 {
                    let glyph = glyphs[(frame + row + stream) % glyphs.count]
                    output += "\u{1b}[3\((row + stream) % 8)m"
                    output += "agent-stream \(stream)  frame \(frame)  row \(row)  "
                    output += String(repeating: glyph, count: 92)
                    output += "\u{1b}[0m\r\n"
                }
            }
            FileHandle.standardOutput.write(Data(output.utf8))
            frame += 1
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
