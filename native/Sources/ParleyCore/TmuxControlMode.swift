import Foundation

/// A held-open tmux control-mode client for pane output plus the two
/// high-frequency operations whose process-spawn cost is visible: terminal
/// input and member-window resize. All other mutations stay on TmuxController's
/// bounded argv path.
///
/// Parser, writer and lifecycle state deliberately use separate serialization
/// domains. A blocked stdin write must never stop stdout from draining, and
/// output notifications must be delivered in the order tmux emitted them.
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
    private let deliveryQueue: DispatchQueue?
    private let onPaneOutput: PaneOutputHandler
    private let onEvent: EventHandler

    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()
    private let parserQueue = DispatchQueue(label: "com.parley.tmux-control.parser")
    private let writerQueue = DispatchQueue(label: "com.parley.tmux-control.writer")
    private var process: Process?
    private var input: FileHandle?
    private var generation: UUID?

    // Parser-queue confined state.
    private var buffer = Data()
    private var insideReplyBlock = false
    private var queuedDeliveryBytes: [String: Int] = [:]
    private var flowPausedPanes: Set<String> = []

    private static let maximumInputChunk = 4_096
    private static let deliveryHighWater = 4 * 1_024 * 1_024
    private static let deliveryLowWater = 1 * 1_024 * 1_024

    public init(
        tmuxExecutable: URL,
        socketPath: URL,
        configPath: URL,
        sessionName: String,
        environment: [String: String],
        deliveryQueue: DispatchQueue? = nil,
        onPaneOutput: @escaping PaneOutputHandler,
        onEvent: @escaping EventHandler
    ) {
        self.tmuxExecutable = tmuxExecutable
        self.socketPath = socketPath
        self.configPath = configPath
        self.sessionName = sessionName
        self.environment = environment
        self.deliveryQueue = deliveryQueue
        self.onPaneOutput = onPaneOutput
        self.onEvent = onEvent
    }

    public var isRunning: Bool {
        stateLock.withLock { process?.isRunning == true }
    }

    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard stateLock.withLock({ process == nil }) else { return }

        let client = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        let connectionGeneration = UUID()
        client.executableURL = tmuxExecutable
        client.arguments = [
            "-S", socketPath.path, "-f", configPath.path,
            "-C", "attach-session", "-f", "pause-after=3", "-t", "=\(sessionName)",
        ]
        client.environment = environment
        client.standardOutput = stdout
        client.standardInput = stdin
        client.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.scheduleExit(reason: nil, generation: connectionGeneration)
            } else {
                self.parserQueue.async { [weak self] in
                    self?.consumeOnParserQueue(chunk, generation: connectionGeneration)
                }
            }
        }
        client.terminationHandler = { [weak self] _ in
            self?.scheduleExit(reason: nil, generation: connectionGeneration)
        }

        parserQueue.sync {
            buffer.removeAll(keepingCapacity: true)
            insideReplyBlock = false
            queuedDeliveryBytes.removeAll(keepingCapacity: true)
            flowPausedPanes.removeAll(keepingCapacity: true)
        }
        stateLock.withLock {
            process = client
            input = stdin.fileHandleForWriting
            generation = connectionGeneration
        }
        do {
            try client.run()
        } catch {
            stateLock.withLock {
                guard generation == connectionGeneration else { return }
                process = nil
                input = nil
                generation = nil
            }
            stdout.fileHandleForReading.readabilityHandler = nil
            client.terminationHandler = nil
            throw error
        }
    }

    /// Forwards raw terminal bytes to one exact tmux pane. The pane id is
    /// syntax-checked and bytes become fixed two-digit hex words, so neither
    /// value can append a second control-mode command.
    @discardableResult
    public func sendInput(toPaneID paneID: String, bytes: ArraySlice<UInt8>) -> Bool {
        guard Self.isIdentifier(paneID, prefix: "%"), !bytes.isEmpty else { return false }
        var accepted = true
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: Self.maximumInputChunk, limitedBy: bytes.endIndex)
                ?? bytes.endIndex
            let hex = bytes[start..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
            accepted = enqueue("send-keys -t \(paneID) -H \(hex)") && accepted
            start = end
        }
        return accepted
    }

    /// Resizes one exact member window. Bounds avoid nonsensical or
    /// pathological allocations while remaining far above useful terminal
    /// dimensions.
    @discardableResult
    public func resizeWindow(_ windowID: String, columns: Int, rows: Int) -> Bool {
        guard Self.isIdentifier(windowID, prefix: "@") else { return false }
        let width = min(10_000, max(2, columns))
        let height = min(10_000, max(2, rows))
        return enqueue("resize-window -t \(windowID) -x \(width) -y \(height)")
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let stopped = stateLock.withLock { () -> (Process, FileHandle)? in
            guard let process, let input else { return nil }
            self.process = nil
            self.input = nil
            generation = nil // suppress EOF/termination as an unexpected exit
            return (process, input)
        }
        guard let (client, stdin) = stopped else { return }
        client.terminationHandler = nil
        if let stdout = client.standardOutput as? Pipe {
            stdout.fileHandleForReading.readabilityHandler = nil
        }
        try? stdin.close()
        if client.isRunning { client.terminate() }
        client.waitUntilExit()
    }

    private func enqueue(_ line: String) -> Bool {
        guard !line.contains("\n"), !line.contains("\r") else { return false }
        guard let commandGeneration = stateLock.withLock({ generation }) else { return false }
        let data = Data((line + "\n").utf8)
        writerQueue.async { [weak self] in
            guard let self else { return }
            let handle = self.stateLock.withLock { () -> FileHandle? in
                guard self.generation == commandGeneration else { return nil }
                return self.input
            }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                self.scheduleExit(
                    reason: "control-mode input failed: \(error.localizedDescription)",
                    generation: commandGeneration
                )
            }
        }
        return true
    }

    private func scheduleExit(reason: String?, generation connectionGeneration: UUID) {
        parserQueue.async { [weak self] in
            self?.finishUnexpectedExit(reason: reason, generation: connectionGeneration)
        }
    }

    private func finishUnexpectedExit(reason: String?, generation connectionGeneration: UUID) {
        let shouldReport = stateLock.withLock { () -> Bool in
            guard generation == connectionGeneration else { return false }
            process = nil
            input = nil
            generation = nil
            return true
        }
        guard shouldReport else { return }
        deliver(event: .exited(reason))
    }

    private func consumeOnParserQueue(_ chunk: Data, generation connectionGeneration: UUID) {
        guard stateLock.withLock({ generation == connectionGeneration }) else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer.subdata(in: buffer.startIndex..<newline)
            if line.last == 0x0D { line.removeLast() }
            buffer.removeSubrange(buffer.startIndex...newline)
            handleOnParserQueue(line: line)
        }
    }

    private func handleOnParserQueue(line: Data) {
        if hasPrefix(line, "%begin ") {
            insideReplyBlock = true
            return
        }
        if hasPrefix(line, "%end ") || hasPrefix(line, "%error ") {
            insideReplyBlock = false
            return
        }
        if insideReplyBlock { return }

        if hasPrefix(line, "%output ") {
            let payload = line.dropFirst("%output ".utf8.count)
            guard let space = payload.firstIndex(of: 0x20),
                  let paneID = String(
                    data: payload.subdata(in: payload.startIndex..<space),
                    encoding: .utf8
                  ), Self.isIdentifier(paneID, prefix: "%") else { return }
            let escaped = payload.subdata(in: payload.index(after: space)..<payload.endIndex)
            deliver(paneID: paneID, bytes: Self.unescape(escaped))
            return
        }
        if hasPrefix(line, "%extended-output ") {
            let payload = line.dropFirst("%extended-output ".utf8.count)
            guard let space = payload.firstIndex(of: 0x20),
                  let paneID = String(
                    data: payload.subdata(in: payload.startIndex..<space),
                    encoding: .utf8
                  ), Self.isIdentifier(paneID, prefix: "%"),
                  let marker = payload.range(of: Data(" : ".utf8)) else { return }
            let escaped = payload.subdata(in: marker.upperBound..<payload.endIndex)
            deliver(paneID: paneID, bytes: Self.unescape(escaped))
            return
        }

        guard let text = String(data: line, encoding: .utf8) else { return }
        let fields = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard let keyword = fields.first else { return }
        switch keyword {
        case "%window-add" where fields.count > 1:
            deliver(event: .windowAdded(String(fields[1])))
        case "%window-close", "%unlinked-window-close":
            guard fields.count > 1 else { return }
            deliver(event: .windowClosed(String(fields[1])))
        case "%window-renamed" where fields.count > 1:
            deliver(event: .windowRenamed(String(fields[1])))
        case "%pane-mode-changed" where fields.count > 1:
            deliver(event: .paneModeChanged(String(fields[1])))
        case "%pause" where fields.count > 1:
            let paneID = String(fields[1])
            guard Self.isIdentifier(paneID, prefix: "%") else { return }
            flowPausedPanes.insert(paneID)
            resumeIfDrained(paneID)
        case "%continue" where fields.count > 1:
            flowPausedPanes.remove(String(fields[1]))
        case "%exit":
            let reason = fields.count > 1 ? String(text.dropFirst("%exit ".count)) : nil
            if let current = stateLock.withLock({ generation }) {
                finishUnexpectedExit(reason: reason, generation: current)
            }
        default:
            break
        }
    }

    private func deliver(paneID: String, bytes: Data) {
        guard !bytes.isEmpty else { return }
        guard let deliveryQueue else {
            onPaneOutput(paneID, bytes)
            return
        }

        queuedDeliveryBytes[paneID, default: 0] += bytes.count
        if queuedDeliveryBytes[paneID, default: 0] >= Self.deliveryHighWater,
           flowPausedPanes.insert(paneID).inserted {
            _ = enqueue("refresh-client -A \(paneID):pause")
        }
        deliveryQueue.async { [weak self, onPaneOutput] in
            onPaneOutput(paneID, bytes)
            self?.parserQueue.async { [weak self] in
                guard let self else { return }
                self.queuedDeliveryBytes[paneID] = max(
                    0,
                    self.queuedDeliveryBytes[paneID, default: 0] - bytes.count
                )
                self.resumeIfDrained(paneID)
            }
        }
    }

    private func resumeIfDrained(_ paneID: String) {
        guard flowPausedPanes.contains(paneID),
              queuedDeliveryBytes[paneID, default: 0] <= Self.deliveryLowWater else { return }
        guard enqueue("refresh-client -A \(paneID):continue") else { return }
        flowPausedPanes.remove(paneID)
    }

    private func deliver(event: Event) {
        if let deliveryQueue {
            deliveryQueue.async { [onEvent] in onEvent(event) }
        } else {
            onEvent(event)
        }
    }

    private func hasPrefix(_ line: Data, _ prefix: String) -> Bool {
        let bytes = Array(prefix.utf8)
        guard line.count >= bytes.count else { return false }
        return line.prefix(bytes.count).elementsEqual(bytes)
    }

    private static func isIdentifier(_ value: String, prefix: Character) -> Bool {
        guard value.first == prefix, value.count > 1 else { return false }
        return value.dropFirst().allSatisfy(\.isNumber)
    }

    /// Decodes tmux control-mode octal escapes (\\ooo) back to raw bytes.
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
