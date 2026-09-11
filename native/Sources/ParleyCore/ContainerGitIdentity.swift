import Foundation

/// Exact shared Git metadata shown in the native launch review. This is a
/// writable mount, not a claim that a vendor has approved a Git operation.
///
/// The value is declared apart from the inspection that produces it. Resolving
/// a worktree means following symlinks and reading Git's own pointers, which
/// needs the platform; naming the result does not. `ContainerConfiguration`
/// and anything that reads a recorded mount depend only on this file.
///
/// `device` and `fileID` pin the identity of the common directory so a path
/// re-pointed later is not silently accepted as the same repository.
public struct ContainerGitAccess: Codable, Equatable, Sendable {
    public let folder: String
    public let commonDirectory: String
    public let device: UInt64
    public let fileID: UInt64

    public init(folder: String, commonDirectory: String, device: UInt64, fileID: UInt64) {
        self.folder = folder
        self.commonDirectory = commonDirectory
        self.device = device
        self.fileID = fileID
    }
}
