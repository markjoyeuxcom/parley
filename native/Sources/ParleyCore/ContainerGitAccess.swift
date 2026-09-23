import Darwin
import Foundation

/// Resolving shared Git metadata: following symlinks with `realpath`, reading
/// Git's pointers, and corroborating them against Git's own registry. The
/// value these produce is declared in `ContainerGitIdentity.swift`, which
/// needs no platform, so a recorded mount can be read without this file.
extension ContainerGitAccess {
    static func canonical(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw ContainerPaneError.refused("A Git path is unavailable; review the worktree again.") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func planned(folder: String, commonDirectory: String) throws -> Self {
        guard folder.hasPrefix("/") else { throw ContainerPaneError.refused("The planned container folder must be absolute.") }
        // A not-yet-created worktree still has an existing parent. Preserve
        // realpath spelling through that parent, including symlink aliases.
        var ancestor = URL(fileURLWithPath: folder)
        var suffix: [String] = []
        var plannedFolder: String
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                let root = String(cString: resolved); free(resolved)
                plannedFolder = suffix.reversed().reduce(root) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
                break
            }
            guard errno == ENOENT, ancestor.path != "/" else { throw ContainerPaneError.refused("The planned container folder could not be resolved.") }
            suffix.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
        let common = try canonical(commonDirectory)
        let attrs = try FileManager.default.attributesOfItem(atPath: common)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
              let fileID = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw ContainerPaneError.refused("The shared Git directory identity could not be read.")
        }
        return Self(folder: plannedFolder, commonDirectory: common, device: device, fileID: fileID)
    }

    /// Read only bounded Git pointers, then corroborate them against Git's
    /// registry. Submodules and arbitrary external gitdirs are not worktrees.
    public static func inspect(folder: String) throws -> Self? {
        let canonicalFolder = try canonical(folder)
        var parent = URL(fileURLWithPath: canonicalFolder)
        while parent.path != "/" {
            let marker = parent.appendingPathComponent(".git")
            switch ManagedWorktreeService.itemState(at: marker.path) {
            case .absent: parent.deleteLastPathComponent(); continue
            case .unknown: throw ContainerPaneError.refused("The working folder's Git metadata could not be inspected.")
            case .present(let directory):
                if directory { return nil }
                guard parent.path == canonicalFolder else {
                    throw ContainerPaneError.refused("Choose the linked worktree root as the container working folder.")
                }
                func pointer(_ url: URL) throws -> String {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attrs[.type] as? FileAttributeType == .typeRegular,
                          (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 4096 else {
                        throw ContainerPaneError.refused("Git pointers must be bounded regular files, not symlinks.")
                    }
                    return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
                }
                let value = try pointer(marker)
                guard value.hasPrefix("gitdir: ") else { throw ContainerPaneError.refused("The worktree Git pointer is invalid.") }
                let gitPath = String(value.dropFirst(8))
                let admin = try canonical(gitPath.hasPrefix("/") ? gitPath : canonicalFolder + "/" + gitPath)
                guard case .present(isDirectory: false) = ManagedWorktreeService.itemState(at: admin + "/commondir") else {
                    throw ContainerPaneError.refused("This Git directory is not a linked worktree. Submodules and external Git directories are not supported by container panes.")
                }
                let commonPointer = try pointer(URL(fileURLWithPath: admin + "/commondir"))
                let common = try canonical(commonPointer.hasPrefix("/") ? commonPointer : admin + "/" + commonPointer)
                guard admin.hasPrefix(common + "/worktrees/"), !admin.dropFirst((common + "/worktrees/").count).contains("/"),
                      try canonical(pointer(URL(fileURLWithPath: admin + "/gitdir"))) == marker.path else {
                    throw ContainerPaneError.refused("Only registered linked worktrees can receive shared Git access.")
                }
                let result = try planned(folder: canonicalFolder, commonDirectory: common)
                let runner = ProcessCommandRunner(timeout: 5, maximumCapturedBytes: 200_001)
                let output = try GitReadBoundary.run(git: URL(fileURLWithPath: "/usr/bin/git"),
                    arguments: ["-C", canonicalFolder, "-c", "core.fsmonitor=false", "worktree", "list", "--porcelain", "-z"],
                    environment: GitReadBoundary.environment(["PATH": "/usr/bin:/bin"]), runner: runner)
                guard output.status == 0, output.stdout.count <= 200_000,
                      RegisteredWorktree.parse(output.stdout).contains(where: { (try? canonical($0.path)) == canonicalFolder }) else {
                    throw ContainerPaneError.refused("Git no longer lists this linked worktree.")
                }
                return result
            }
        }
        return nil
    }
}
