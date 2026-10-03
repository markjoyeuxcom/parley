import Darwin
import Foundation

/// Whether Claude Code's own sandbox is switched on for a folder, read from
/// the places Claude reads it, in Claude's precedence: managed settings, the
/// environment, the project's local settings, the project's shared settings,
/// the person's settings. `enabled` is nil when nothing sets it or nothing
/// could be read; unknown is never reported as off or on.
public struct ClaudeSandboxFact: Equatable, Sendable {
    public let enabled: Bool?
    /// Where the value came from, for the review and for `whoami`.
    public let source: String?

    public init(enabled: Bool?, source: String?) {
        self.enabled = enabled
        self.source = source
    }

    public static let unset = ClaudeSandboxFact(enabled: nil, source: nil)
}

/// Claude Code's sandbox settings are the person's own configuration.
/// Parley reads one boolean from them and never writes them: whether the
/// sandbox is on decides only how Parley describes and checks a pane's
/// requests. The sandbox denies Unix sockets unless its `allowUnixSockets`
/// list admits one, so a pane under it may not reach the ticket socket.
/// One launch review's Claude sandbox fact. The review's ticket policy is
/// evaluated about five times per render, and each read up to four settings
/// files on the main actor (review of 22 September 2026, 96c795d7); the fact is
/// read once per folder while the review is open. Only a Claude pane on this
/// Mac has one.
public final class ClaudeSandboxFactCache {
    private let read: (String) -> ClaudeSandboxFact
    private var folder: String?
    private var cached: ClaudeSandboxFact?
    /// Settings reads so far (checks).
    public private(set) var reads = 0

    public init(read: @escaping (String) -> ClaudeSandboxFact = { ClaudeHostConfiguration.sandbox(folder: $0) }) {
        self.read = read
    }

    public func fact(kind: PaneKind, folder: String, inContainer: Bool) -> ClaudeSandboxFact? {
        guard kind == .claude, !inContainer else { return nil }
        if self.folder == folder, let cached { return cached }
        let fact = read(folder)
        reads += 1
        self.folder = folder
        cached = fact
        return fact
    }
}

public enum ClaudeHostConfiguration {
    public static let maximumSettingsBytes = 1 << 20
    public static let managedSettingsFile = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
    public static let forceEnvironmentKey = "CLAUDE_CODE_FORCE_SANDBOX"

    public static func sandbox(
        folder: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        managedFile: URL = managedSettingsFile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ClaudeSandboxFact {
        if let value = enabled(in: managedFile, fileManager: fileManager) {
            return ClaudeSandboxFact(enabled: value, source: managedFile.path)
        }
        if let forced = environment[forceEnvironmentKey], ["1", "true", "yes"].contains(forced.lowercased()) {
            return ClaudeSandboxFact(enabled: true, source: forceEnvironmentKey)
        }
        let project = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        for file in [project.appendingPathComponent("settings.local.json"), project.appendingPathComponent("settings.json"),
                     home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("settings.json")] {
            if let value = enabled(in: file, fileManager: fileManager) {
                return ClaudeSandboxFact(enabled: value, source: file.path)
            }
        }
        return .unset
    }

    /// `sandbox.enabled` from one settings file, or nil when the file is
    /// absent, unreadable, too large, not a JSON object, or silent on it.
    public static func enabled(in file: URL, fileManager: FileManager) -> Bool? {
        guard let data = boundedRegularFile(file, maximumBytes: maximumSettingsBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sandbox = object["sandbox"] as? [String: Any],
              let enabled = sandbox["enabled"] as? Bool else { return nil }
        return enabled
    }

    /// The bytes of a regular file of at most `maximumBytes`, following a
    /// symlink as Claude does, or nil. The project's `.claude` folder is the
    /// agent's to write, so the size is checked on the opened descriptor, not
    /// on the path (a symlink's own size said nothing of its target), and a
    /// FIFO or device is never waited on: a FIFO there used to stall the launch
    /// review on the main actor until a writer appeared (review of 22
    /// September 2026, 96c795d7). The type is checked before the open too, so
    /// a device is not opened at all in the ordinary case. Nothing here can
    /// stop a hung network or FUSE mount from blocking a regular read.
    static func boundedRegularFile(_ file: URL, maximumBytes: Int) -> Data? {
        try? BoundedRegularFile.read(file, maximumBytes: maximumBytes)
    }
}

/// One regular file read through one descriptor: its type and size are
/// checked on that descriptor, a FIFO or device is never opened or waited
/// on, and nothing past the bound is kept, even if the file grows during the
/// read. A symlink is followed, as an open dialog or a vendor follows it; the
/// bytes come from the file the descriptor names, not a later lookup. Used
/// for vendor settings, the person's chosen files and a pack's re-read files
/// (Codex's review of MR !146: an image was read with `Data(contentsOf:)`
/// after a separate size check, so a file that grew or became a FIFO could
/// be read whole or block the capture). Nothing here can stop a hung network
/// or FUSE mount from blocking a regular read.
public enum BoundedRegularFile {
    public enum Failure: Error, Equatable, Sendable {
        case missing
        case notRegularFile
        case tooLarge
        case unreadable
    }

    public static func read(_ file: URL, maximumBytes: Int) throws -> Data {
        var target = stat()
        guard stat(file.path, &target) == 0 else { throw errno == ENOENT ? Failure.missing : Failure.unreadable }
        guard target.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ENOENT ? Failure.missing : Failure.unreadable }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw Failure.unreadable }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        guard metadata.st_size <= off_t(maximumBytes) else { throw Failure.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unreadable }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        // The file grew past the bound after the check.
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        return data
    }
}
