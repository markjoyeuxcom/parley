import Darwin
import Foundation

/// Pins each directory and field before validating it. Requesters own the
/// endpoint contents; renames and symlinks must never redirect an app read.
public final class RelayRequestFields {
    private let directory: Int32

    public init(runtimeDirectory: URL, components: [String]) throws {
        var descriptor = open(runtimeDirectory.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RelayFileTransportError.runtime("could not open request runtime") }
        do {
            try Self.validateDirectory(descriptor)
            for component in components {
                guard !component.isEmpty, component != ".", component != "..", !component.contains("/"), !component.contains("\0") else {
                    throw RelayFileTransportError.runtime("invalid request directory component")
                }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw RelayFileTransportError.runtime("invalid request directory") }
                close(descriptor)
                descriptor = next
                try Self.validateDirectory(descriptor)
            }
            directory = descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit { close(directory) }

    public func read(_ name: String, maximumBytes: Int, optional: Bool = false) throws -> String? {
        guard let data = try readData(name, maximumBytes: maximumBytes, optional: optional) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayFileTransportError.runtime("request field \(name) is not UTF-8")
        }
        return text
    }

    /// The field's bytes, with the same pinned, no-follow, owner-only and
    /// bounded read as `read`; for a body that may be an image.
    public func readData(_ name: String, maximumBytes: Int, optional: Bool = false) throws -> Data? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != "..", maximumBytes >= 0 else {
            throw RelayFileTransportError.runtime("invalid request field name or bound")
        }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, optional, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw RelayFileTransportError.runtime("invalid request field \(name)") }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            throw RelayFileTransportError.runtime("invalid request field \(name)")
        }
        guard metadata.st_size <= maximumBytes else { throw RelayFileTransportError.fieldTooLarge(name) }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: min(8_192, maximumBytes + 1))
        while true {
            // Read at most one byte beyond the bound, even if the file grows.
            let count = Darwin.read(descriptor, &bytes, min(bytes.count, maximumBytes + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw RelayFileTransportError.runtime("could not read request field \(name)") }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= maximumBytes else { throw RelayFileTransportError.fieldTooLarge(name) }
        }
        return data
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw RelayFileTransportError.runtime("request directory is not owner-only")
        }
    }
}
