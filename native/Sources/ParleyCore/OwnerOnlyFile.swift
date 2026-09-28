import Darwin
import Foundation

/// Writes a whole file that only its owner may read, durably: created
/// owner-only under a temporary name beside it, written, synced, and only then
/// renamed into place. The file is never visible with wider permissions or
/// half-written, and after a crash it is either the old file or the new one.
///
/// Every store here used to write with `Data.write(.atomic)` and `chmod` after
/// the rename, with no sync: for a moment the renamed file was 0644 (the relay
/// credentials included), and a crash in that moment, or a torn file after a
/// power loss, was refused at the next launch by the store's own owner-only
/// check (review of 22 September 2026, 4b656187).
public enum OwnerOnlyFile {
    /// `fileManager` is the store's own; if it adopts `OwnerOnlyFileObserver`
    /// it is told the moment the file is committed, where a check puts another
    /// writer's replacement. A store must never pair the bytes it wrote with a
    /// file identity taken after the commit.
    public static func write(_ data: Data, to file: URL, fileManager: FileManager = .default) throws {
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var committed = false
        defer {
            close(descriptor)
            if !committed { unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EIO : errno)) }
                offset += count
            }
        }
        // A umask can only narrow the creation mode; state it anyway.
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0, fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // The rename is the commit point.
        guard rename(temporary.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        committed = true
        try (fileManager as? OwnerOnlyFileObserver)?.ownerOnlyFileCommitted(file)
    }
}

/// Adopted only by a check's file manager: see `OwnerOnlyFile.write`.
public protocol OwnerOnlyFileObserver: AnyObject {
    func ownerOnlyFileCommitted(_ file: URL) throws
}
