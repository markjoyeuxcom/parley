import Foundation

/// A tmux control-mode client used only as a notification stream: per-pane
/// output bytes and window lifecycle events. It never issues tmux commands —
/// input, sizing and every mutation stay on the one-shot command path, which
/// tmux serializes server-side — so no command/reply correlation exists here.
///
/// Control mode runs over plain pipes; no pty is involved. Output payloads are
/// octal-escaped by tmux (\ooo for every non-printable byte, including \n and
/// backslash), so line-based framing is sound and payloads are unescaped back
/// to raw bytes before delivery.
public final class TmuxControlModeConnection: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case windowAdded(String)
        case windowClosed(String)
        case windowRenamed(String)
        case paneModeChanged(String)
        case exited(String?)
    }

    public typealias PaneOutputHandler = @Sendable (_ paneID: String, _ bytes: Data) -> Void
    public typealias EventHandler = @Sendable (_ event: Event) -> Void

    private let tmuxExecutable: URL
    private let socketPath: URL
    private let configPath: URL
    private let sessionName: String
    private let environment: [String: String]
    private let onPaneOutput: PaneOutputHandler
    private let onEvent: EventHandler

    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var insideReplyBlock = false
    private var reportedExit = false

    public init(
        tmuxExecutable: URL,
        socketPath: URL,
        configPath: URL,
        sessionName: String,
        environment: [String: String],
        onPaneOutput: @escaping PaneOutputHandler,
        onEvent: @escaping EventHandler
    ) {
        self.tmuxExecutable = tmuxExecutable
        self.socketPath = socketPath
        self.configPath = configPath
        self.sessionName = sessionName
        self.environment = environment
        self.onPaneOutput = onPaneOutput
        self.onEvent = onEvent
    }

    public var isRunning: Bool {
        lock.withLock { process?.isRunning == true }
    }

    public func start() throws {
        try lock.withLock {
            guard process == nil else { return }
            let client = Process()
            client.executableURL = tmuxExecutable
            client.arguments = [
                "-S", socketPath.path, "-f", configPath.path,
                "-C", "attach-session", "-t", "=\(sessionName)",
            ]
            client.environment = environment
            let stdout = Pipe()
            client.standardOutput = stdout
            client.standardInput = Pipe()  // held open; closing it detaches the client
            client.standardError = FileHandle.nullDevice
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    self.deliverExitIfNeeded(reason: nil)
                    return
                }
                self.consume(chunk)
            }
            client.terminationHandler = { [weak self] _ in
                self?.deliverExitIfNeeded(reason: nil)
            }
            try client.run()
            process = client
        }
    }

    /// Writes one tmux command line through the control client. Used only for
    /// high-frequency traffic (keystroke forwarding, window resizes) where a
    /// process spawn per event would be felt; every reply block is skipped by
    /// the parser. Arguments must be shell-word safe — callers pass pane ids
    /// and hex bytes only.
    public func sendCommand(_ line: String) {
        lock.withLock {
            guard let stdin = (process?.standardInput as? Pipe)?.fileHandleForWriting else { return }
            stdin.write(Data((line + "\n").utf8))
        }
    }

    public func stop() {
        let client = lock.withLock { () -> Process? in
            let running = process
            process = nil
            return running
        }
        guard let client else { return }
        client.terminationHandler = nil
        if let stdout = client.standardOutput as? Pipe {
            stdout.fileHandleForReading.readabilityHandler = nil
        }
        client.terminate()
        client.waitUntilExit()
    }

    private func deliverExitIfNeeded(reason: String?) {
        let shouldReport = lock.withLock { () -> Bool in
            guard !reportedExit else { return false }
            reportedExit = true
            return true
        }
        if shouldReport { onEvent(.exited(reason)) }
    }

    private func consume(_ chunk: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer.subdata(in: buffer.startIndex..<newline)
                if line.last == 0x0D { line.removeLast() }
                lines.append(line)
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines { handle(line: line) }
    }

    private func handle(line: Data) {
        // Reply blocks (%begin ... %end/%error) belong to commands; this
        // client issues none, but skipping their bodies keeps a stray block
        // from being misread as notifications.
        if hasPrefix(line, "%begin ") {
            lock.withLock { insideReplyBlock = true }
            return
        }
        if hasPrefix(line, "%end ") || hasPrefix(line, "%error ") {
            lock.withLock { insideReplyBlock = false }
            return
        }
        if lock.withLock({ insideReplyBlock }) { return }

        if hasPrefix(line, "%output ") {
            let payload = line.dropFirst("%output ".utf8.count)
            guard let space = payload.firstIndex(of: 0x20),
                  let paneID = String(data: payload.subdata(in: payload.startIndex..<space), encoding: .utf8),
                  paneID.hasPrefix("%") else { return }
            let escaped = payload.subdata(in: payload.index(after: space)..<payload.endIndex)
            onPaneOutput(paneID, Self.unescape(escaped))
            return
        }
        guard let text = String(data: line, encoding: .utf8) else { return }
        let fields = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard let keyword = fields.first else { return }
        switch keyword {
        case "%window-add" where fields.count > 1:
            onEvent(.windowAdded(String(fields[1])))
        case "%window-close", "%unlinked-window-close":
            guard fields.count > 1 else { return }
            onEvent(.windowClosed(String(fields[1])))
        case "%window-renamed" where fields.count > 1:
            onEvent(.windowRenamed(String(fields[1])))
        case "%pane-mode-changed" where fields.count > 1:
            onEvent(.paneModeChanged(String(fields[1])))
        case "%exit":
            deliverExitIfNeeded(reason: fields.count > 1 ? String(text.dropFirst("%exit ".count)) : nil)
        default:
            break
        }
    }

    private func hasPrefix(_ line: Data, _ prefix: String) -> Bool {
        let bytes = Array(prefix.utf8)
        guard line.count >= bytes.count else { return false }
        return line.prefix(bytes.count).elementsEqual(bytes)
    }

    /// Decodes tmux control-mode octal escapes (\ooo) back to raw bytes.
    static func unescape(_ escaped: Data) -> Data {
        var result = Data(capacity: escaped.count)
        var index = escaped.startIndex
        while index < escaped.endIndex {
            let byte = escaped[index]
            if byte == 0x5C, escaped.distance(from: index, to: escaped.endIndex) >= 4 {
                let d1 = escaped[escaped.index(index, offsetBy: 1)]
                let d2 = escaped[escaped.index(index, offsetBy: 2)]
                let d3 = escaped[escaped.index(index, offsetBy: 3)]
                if (0x30...0x37).contains(d1), (0x30...0x37).contains(d2), (0x30...0x37).contains(d3) {
                    let value = (Int(d1 - 0x30) << 6) | (Int(d2 - 0x30) << 3) | Int(d3 - 0x30)
                    result.append(UInt8(truncatingIfNeeded: value))
                    index = escaped.index(index, offsetBy: 4)
                    continue
                }
            }
            result.append(byte)
            index = escaped.index(after: index)
        }
        return result
    }
}
