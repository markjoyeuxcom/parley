import Darwin
import Foundation

/// The person's durable choices about agent command runs: approve requests
/// without a preview, and end a clean run's pane instead of handing it to an
/// interactive shell. These are execution authority, so they do not live in
/// an ordinary preference domain that an agent process could write. They are
/// one small owner-only file inside the application directory that every
/// agent boundary denies, validated narrowly on every read, with anything
/// missing, malformed, foreign or oversized reading as "off".
public struct CommandRunAuthorization: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var automaticApproval: Bool
    public var closeCleanPanes: Bool
    public var updatedAt: Date

    public init(automaticApproval: Bool, closeCleanPanes: Bool, updatedAt: Date = Date()) {
        version = Self.currentVersion
        self.automaticApproval = automaticApproval
        self.closeCleanPanes = closeCleanPanes
        self.updatedAt = updatedAt
    }
}

/// What a Settings change means once the save has succeeded or failed.
/// Turning on fails closed (nothing changes); turning off always applies for
/// this session, and says plainly when the saved choice may come back.
public enum CommandRunAuthorizationChange {
    public struct Outcome: Equatable, Sendable {
        /// Whether the in-memory switch takes the requested value.
        public let applied: Bool
        public let message: String?
        public init(applied: Bool, message: String?) {
            self.applied = applied
            self.message = message
        }
    }

    public static func outcome(turningOn: Bool, saveError: String?, setting: String) -> Outcome {
        guard let saveError else { return Outcome(applied: true, message: nil) }
        if turningOn {
            return Outcome(applied: false, message: "\(setting) could not be turned on and remains off: \(saveError)")
        }
        return Outcome(applied: true, message: "\(setting) is off for this session, but the choice could not be saved: \(saveError) The previously saved choice may return after Parley relaunches; turn it off again in Settings then.")
    }
}

public final class CommandRunAuthorizationStore: @unchecked Sendable {
    public struct Loaded: Equatable, Sendable {
        public let automaticApproval: Bool
        public let closeCleanPanes: Bool
        /// Why the file was ignored, if it existed but could not be trusted.
        public let error: String?
        public static let off = Loaded(automaticApproval: false, closeCleanPanes: false, error: nil)
        public init(automaticApproval: Bool, closeCleanPanes: Bool, error: String?) {
            self.automaticApproval = automaticApproval
            self.closeCleanPanes = closeCleanPanes
            self.error = error
        }
    }

    public static let fileName = "command-run-authorization.json"
    public static let maximumBytes = 4_096
    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    /// Never throws: a store that cannot be trusted is treated as "off" and
    /// says why, so the Settings UI can show that the choice was not applied.
    public func load() -> Loaded {
        lock.withLock {
            var info = stat()
            guard lstat(file.path, &info) == 0 else {
                return errno == ENOENT ? .off : Loaded(automaticApproval: false, closeCleanPanes: false, error: "The command-run authorization file could not be inspected: \(String(cString: strerror(errno)))")
            }
            guard info.st_mode & S_IFMT == S_IFREG else { return off("is not a regular file") }
            guard info.st_uid == getuid() else { return off("is not owned by you") }
            guard info.st_mode & 0o077 == 0 else { return off("is readable by other users") }
            guard info.st_size <= Self.maximumBytes else { return off("is larger than \(Self.maximumBytes) bytes") }
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { return off("could not be opened: \(String(cString: strerror(errno)))") }
            defer { close(descriptor) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            guard let data = try? handle.readToEnd(), data.count <= Self.maximumBytes else { return off("could not be read") }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let value = try? decoder.decode(CommandRunAuthorization.self, from: data) else { return off("is not a valid authorization record") }
            guard value.version == CommandRunAuthorization.currentVersion else { return off("has an unsupported version \(value.version)") }
            return Loaded(automaticApproval: value.automaticApproval, closeCleanPanes: value.closeCleanPanes, error: nil)
        }
    }

    /// Writes atomically as an owner-only file; a failure leaves the previous
    /// record (or its absence) in place.
    public func save(automaticApproval: Bool, closeCleanPanes: Bool) throws {
        try lock.withLock {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(CommandRunAuthorization(automaticApproval: automaticApproval, closeCleanPanes: closeCleanPanes))
            let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var written = false
            defer { if !written { unlink(temporary.path) } }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            written = true
        }
    }

    private func off(_ problem: String) -> Loaded {
        Loaded(automaticApproval: false, closeCleanPanes: false,
            error: "The command-run authorization file \(problem); both switches are treated as off until you set them again in Settings.")
    }
}
