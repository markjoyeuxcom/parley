import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import ParleyCore

private struct GhosttySoakReport: Codable {
    let schemaVersion: Int
    let startedAt: Date
    let completedAt: Date
    let durationMilliseconds: Int64
    let paneCount: Int
    let rounds: Int
    let deliveredInputs: Int
    let hiddenPaneInputs: Int
    let paneProcessesTerminated: Bool

    var passed: Bool {
        paneCount == 8
            && deliveredInputs == paneCount * rounds
            && hiddenPaneInputs == paneCount
            && paneProcessesTerminated
    }
}

private enum GhosttySoakError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self { case let .failed(message): message }
    }
}

@main
private enum ParleyGhosttySoak {
    @MainActor
    static func main() {
        do {
            if CommandLine.arguments.contains("--debug") {
                TerminalDebugLog.enable([.lifecycle, .input, .actions])
            }
            let report = try run()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var encoded = try encoder.encode(report)
            encoded.append(Data("\n".utf8))
            if let output = try requestedOutputURL() {
                try encoded.write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            } else {
                FileHandle.standardOutput.write(encoded)
            }
            if !report.passed { Darwin.exit(1) }
        } catch {
            FileHandle.standardError.write(Data("Ghostty soak failed: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    @MainActor
    private static func run() throws -> GhosttySoakReport {
        let startedAt = Date()
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-ghostty-soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let paneCount = 8
        let rounds = requestedRounds()
        let controller = TerminalController { builder in
            builder.withBackgroundOpacity(1)
            builder.withCustom("copy-on-select", "false")
        }
        var terminals: [AppTerminalView] = []
        var windows: [NSWindow] = []
        var processIDs: [pid_t] = []

        for index in 0..<paneCount {
            let terminal = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec,
                workingDirectory: directory.path,
                command: GhosttyLaunchCommand.render(["/bin/zsh", "-f", "-i"]),
                waitAfterCommand: true,
                resizeThrottleMilliseconds: 64
            )
            let window = NSWindow(
                contentRect: NSRect(x: 12 * index, y: 12 * index, width: 420, height: 260),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = terminal
            terminal.controller = controller
            window.orderFront(nil)
            terminals.append(terminal)
            windows.append(window)
        }

        guard pump(until: {
            terminals.allSatisfy { $0.foregroundPid != nil && $0.ttyName != nil }
        }, timeout: 8) else {
            let pidCount = terminals.count(where: { $0.foregroundPid != nil })
            let ttyCount = terminals.count(where: { $0.ttyName != nil })
            throw GhosttySoakError.failed(
                "one or more Ghostty shells did not expose a live PTY (PID \(pidCount)/\(paneCount), TTY \(ttyCount)/\(paneCount))"
            )
        }

        for index in terminals.indices {
            _ = terminals[index].acquireProgrammaticFocus()
            let ready = directory.appendingPathComponent("pane-\(index)-ready")
            guard terminals[index].paste(
                text: GhosttyLaunchCommand.render(["/usr/bin/touch", ready.path])
            ), terminals[index].sendKey(.enter) else {
                throw GhosttySoakError.failed("pane \(index) refused its readiness probe")
            }
        }
        guard pump(until: {
            (0..<paneCount).allSatisfy {
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("pane-\($0)-ready").path
                )
            }
        }, timeout: 8) else {
            throw GhosttySoakError.failed("one or more Ghostty shells did not become input-ready")
        }

        var delivered = 0
        for round in 0..<rounds {
            for index in terminals.indices {
                _ = terminals[index].acquireProgrammaticFocus()
                let marker = directory.appendingPathComponent("pane-\(index)-round-\(round)")
                let pidFile = directory.appendingPathComponent("pane-\(index)-pid")
                let payload = "echo $$ > \(GhosttyLaunchCommand.render([pidFile.path])); printf 'pane=\(index) round=\(round) %0800d\\n' 0; /usr/bin/touch \(GhosttyLaunchCommand.render([marker.path]))"
                guard terminals[index].paste(text: payload), terminals[index].sendKey(.enter) else {
                    throw GhosttySoakError.failed("pane \(index) refused input in round \(round)")
                }
                delivered += 1
            }
            guard pump(until: {
                (0..<paneCount).allSatisfy { index in
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("pane-\(index)-round-\(round)").path
                    )
                }
            }, timeout: 8) else {
                let missing = (0..<paneCount).filter { index in
                    !FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("pane-\(index)-round-\(round)").path
                    )
                }.map(String.init).joined(separator: ", ")
                throw GhosttySoakError.failed(
                    "round \(round) did not complete in panes: \(missing)"
                )
            }
        }

        for index in 0..<paneCount {
            let text = try String(
                contentsOf: directory.appendingPathComponent("pane-\(index)-pid"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = pid_t(text) else {
                throw GhosttySoakError.failed("pane \(index) reported an invalid process id")
            }
            processIDs.append(pid)
        }

        for window in windows { window.orderOut(nil) }
        for index in terminals.indices {
            _ = terminals[index].acquireProgrammaticFocus()
            let marker = directory.appendingPathComponent("pane-\(index)-hidden")
            guard terminals[index].paste(text: "/usr/bin/touch \(GhosttyLaunchCommand.render([marker.path]))"),
                  terminals[index].sendKey(.enter) else {
                throw GhosttySoakError.failed("hidden pane \(index) refused input")
            }
        }
        guard pump(until: {
            (0..<paneCount).allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("pane-\($0)-hidden").path)
            }
        }, timeout: 8) else {
            throw GhosttySoakError.failed("closing the window stopped one or more app-resident panes")
        }

        for terminal in terminals { terminal.controller = nil }
        let terminated = pump(until: {
            processIDs.allSatisfy {
                errno = 0
                return Darwin.kill($0, 0) != 0 && errno == ESRCH
            }
        }, timeout: 8)
        for window in windows { window.close() }

        let completedAt = Date()
        return GhosttySoakReport(
            schemaVersion: 3,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: Int64(
                max(0, completedAt.timeIntervalSince(startedAt) * 1_000).rounded()
            ),
            paneCount: paneCount,
            rounds: rounds,
            deliveredInputs: delivered,
            hiddenPaneInputs: paneCount,
            paneProcessesTerminated: terminated
        )
    }

    private static func requestedOutputURL() throws -> URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--output") else { return nil }
        guard CommandLine.arguments.indices.contains(index + 1) else {
            throw GhosttySoakError.failed("--output requires a file path")
        }
        let path = CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw GhosttySoakError.failed("--output requires a non-empty file path")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func requestedRounds() -> Int {
        guard let index = CommandLine.arguments.firstIndex(of: "--rounds"),
              CommandLine.arguments.indices.contains(index + 1),
              let value = Int(CommandLine.arguments[index + 1]) else { return 25 }
        return min(max(value, 1), 500)
    }

    @MainActor
    private static func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
