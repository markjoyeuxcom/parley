import Darwin
import Foundation

public struct ContainerPaneRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var paneID: String
    public var generation: Int
    public var configuration: ContainerConfiguration
    public var volume: String
    public var runtime: String
    public var containerID: String?
    public var removed: Bool
    public var createdAt: Date
}

/// Native owner of fixed-argv Docker operations. No socket, credentials store,
/// receipt file or daemon authority is mounted into a vendor container.
public final class ContainerPaneService: @unchecked Sendable {
    private struct Document: Codable {
        var owner = UUID().uuidString.lowercased()
        var records: [ContainerPaneRecord] = []
    }
    private let directory: URL
    private let file: URL
    private let environment: [String: String]
    private let runner: CommandRunning
    private let lock = NSRecursiveLock()
    private var initialDocument = Document()

    public init(directory: URL, environment: [String: String], runner: CommandRunning = ProcessCommandRunner(timeout: 12, maximumCapturedBytes: 200_001)) throws {
        self.directory = directory
        file = directory.appendingPathComponent("container-panes.json")
        self.environment = ["HOME": environment["HOME"] ?? NSHomeDirectory(), "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"]
        self.runner = runner
    }

    private func read() throws -> Document {
        guard FileManager.default.fileExists(atPath: file.path) else { return initialDocument }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 2_000_000 else {
            throw ContainerPaneError.refused("Container ownership records are unreadable or unsafe; cleanup is unavailable.")
        }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
    }

    private func save(_ document: Document) throws {
        guard document.records.count <= 500 else { throw ContainerPaneError.refused("Remove old container records in Status Center before creating more containers.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(document)
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        initialDocument = document
    }

    public func records() throws -> [ContainerPaneRecord] { try lock.withLock { try read().records } }

    private func run(_ executable: String, _ arguments: [String], token: String? = nil) throws -> CommandOutput {
        var childEnvironment = environment
        if let token { childEnvironment["PARLEY_RELAY_TOKEN"] = token }
        return try runner.run(executable: URL(fileURLWithPath: executable), arguments: arguments, environment: childEnvironment, input: nil)
    }

    private func checked(_ executable: String, _ arguments: [String], token: String? = nil) throws -> String {
        let result = try run(executable, arguments, token: token)
        guard result.status == 0, result.stdout.count <= 200_000, result.stderr.count <= 200_000 else {
            // Never return argv: create's environment and paths are capability-bearing.
            let detail = String(result.stderrText.prefix(1200)).filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
            throw ContainerPaneError.refused("Docker could not complete the operation (status \(result.status)). \(detail)")
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checked(_ configuration: ContainerConfiguration, _ arguments: [String]) throws -> String {
        try checked(configuration.dockerExecutable, ["--host", configuration.daemonEndpoint] + arguments)
    }

    private func verifyDaemon(_ configuration: ContainerConfiguration) throws {
        try ContainerLaunchProjection.validate(configuration)
        let actual = try checked(configuration, ["info", "--format", "{{.ID}}"])
        guard actual == configuration.daemonID else { throw ContainerPaneError.refused("The Docker daemon changed since the preview. Review the container launch again.") }
    }

    /// Read-only host discovery plus a disposable vendor startup probe. It never
    /// pulls images, uses a host login, grants extra capabilities or contacts a model.
    public func preview(image: String, vendor: PaneKind, legacyCodexSandbox: Bool) throws -> ContainerConfiguration {
        let image = image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [.codex, .claude].contains(vendor), !image.isEmpty, image.utf8.count <= 256,
              !image.hasPrefix("-"), !image.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ContainerPaneError.refused("Choose a locally installed image containing /usr/local/bin/claude or /usr/local/bin/codex.")
        }
        let executable = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { throw ContainerPaneError.refused("Install and start a local Docker-compatible runtime first.") }
        let endpoint = try checked(executable, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
        guard endpoint.hasPrefix("unix:///") else { throw ContainerPaneError.refused("The selected Docker context is not local. Remote daemons are unsupported.") }
        let prefix = ["--host", endpoint]
        let daemon = try checked(executable, prefix + ["info", "--format", "{{.ID}}"])
        let id = try checked(executable, prefix + ["image", "inspect", "--format", "{{.Id}}", image])
        let configuration = ContainerConfiguration(dockerExecutable: executable, daemonEndpoint: endpoint, daemonID: daemon,
            imageID: id, imageName: image, legacyCodexSandbox: legacyCodexSandbox)
        try ContainerLaunchProjection.validate(configuration)
        let probeID = UUID().uuidString.lowercased()
        let probeCID = directory.appendingPathComponent("container-\(probeID).cid")
        var args = prefix + ["create", "--rm", "--name", "parley-\(probeID)", "--cidfile", probeCID.path,
            "--label", "\(ContainerLaunchProjection.ownerLabel)=\(probeID)", "--label", "\(ContainerLaunchProjection.runtimeLabel)=PROBE", "--log-driver=none", "--network=none", "--cap-drop=ALL", "--security-opt=no-new-privileges=true",
            "--user", "\(getuid()):\(getgid())", "--env", "HOME=\(ContainerLaunchProjection.home)",
            "--tmpfs", "\(ContainerLaunchProjection.home):uid=\(getuid()),gid=\(getgid()),mode=700",
            "--entrypoint", "/usr/local/bin/\(vendor.rawValue)", id]
        if vendor == .codex {
            if legacyCodexSandbox { args += ["-c", "features.use_legacy_landlock=true"] }
            args += ["sandbox", "--", "/bin/true"]
        } else { args += ["--version"] }
        try lock.withLock {
            var document = try read()
            var record = ContainerPaneRecord(id: probeID, paneID: "image-check", generation: 0, configuration: configuration,
                volume: "", runtime: "PROBE", containerID: nil, removed: false, createdAt: Date())
            document.records.append(record)
            try save(document)
            do {
                let id = try checked(executable, args)
                guard ContainerLaunchProjection.isHex(id, length: 64) else { throw ContainerPaneError.refused("The image check has no valid container receipt.") }
                record.containerID = id
                document.records[document.records.count - 1] = record
                try save(document)
                _ = try checked(configuration, ["start", "--attach", id])
                try remove(record)
            } catch {
                // A failed probe is cleaned up when possible. A daemon outage
                // leaves its receipt visible rather than forgetting a process.
                try? remove(record)
                throw error
            }
        }
        return configuration
    }

    public func validateFolder(_ folder: String, protectedDirectories: [String]) throws {
        guard let resolved = realpath(folder, nil) else {
            throw ContainerPaneError.refused("The container working folder is no longer available.")
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard canonical == folder, folder != "/", folder != NSHomeDirectory() else {
            throw ContainerPaneError.refused("Choose one canonical project folder for the container, not the home directory or filesystem root.")
        }
        for protected in protectedDirectories {
            let protected = URL(fileURLWithPath: protected).resolvingSymlinksInPath().standardizedFileURL.path
            guard folder != protected, !protected.hasPrefix(folder + "/"), !folder.hasPrefix(protected + "/") else {
                throw ContainerPaneError.refused("The project overlaps Parley's protected runtime files.")
            }
        }
        var parent = URL(fileURLWithPath: folder)
        while parent.path != "/" {
            let git = parent.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue, (try? FileManager.default.attributesOfItem(atPath: git.path)[.type] as? FileAttributeType) != .typeSymbolicLink else { throw ContainerPaneError.refused("Linked worktrees and submodules need additional Git mounts and are not supported by container panes yet. Use a normal repository checkout.") }
                break
            }
            parent.deleteLastPathComponent()
        }
    }

    private func volumeName(paneID: String, owner: String) -> String {
        "parley-\(owner)-\(paneID)"
    }

    /// Creates a stopped container and durably records its daemon-issued ID
    /// before Ghostty can attach. --cidfile also preserves an uncertain create.
    public func prepare(configuration: ContainerConfiguration, pane: WorkbenchPane, endpoint: String,
                        protocolDirectory: String, shimDirectory: String, token: String, vendorArguments: [String], runtime: String) throws -> String {
        try lock.withLock {
            try verifyDaemon(configuration)
            let actualImage = try checked(configuration, ["image", "inspect", "--format", "{{.Id}}", configuration.imageID])
            guard actualImage == configuration.imageID else { throw ContainerPaneError.refused("The reviewed image is no longer installed.") }
            var document = try read()
            guard !document.records.contains(where: { $0.paneID == pane.id && !$0.removed }) else {
                throw ContainerPaneError.refused("This pane still has a recorded container. Remove it in Status Center before starting another.")
            }
            let owner = UUID().uuidString.lowercased()
            let volume = volumeName(paneID: pane.id, owner: document.owner)
            let facts = ContainerLaunchFacts(paneID: pane.id, generation: pane.launchGeneration, vendor: pane.kind, folder: pane.cwd,
                endpoint: endpoint, protocolDirectory: protocolDirectory, shimDirectory: shimDirectory, uid: getuid(), gid: getgid(),
                volume: volume, owner: owner, runtime: runtime)
            var argv = try ContainerLaunchProjection.createArguments(configuration: configuration, facts: facts, vendorArguments: vendorArguments)
            let record = ContainerPaneRecord(id: owner, paneID: pane.id, generation: pane.launchGeneration,
                configuration: configuration, volume: volume, runtime: runtime, containerID: nil, removed: false, createdAt: Date())
            document.records.removeAll { $0.removed && sameHome($0, record) }
            document.records.append(record)
            try save(document)
            // Ownership is app-created metadata; a foreign volume with the same
            // name is refused. No host files or pane capability enter this helper.
            let existing = try checked(configuration, ["volume", "ls", "--filter", "name=^\(volume)$", "--format", "{{.Name}}"])
            if existing.isEmpty {
                _ = try checked(configuration, ["volume", "create", "--label", "com.parley.volume-owner=\(document.owner)", volume])
            }
            let volumeOwner = try checked(configuration, ["volume", "inspect", "--format", "{{index .Labels \"com.parley.volume-owner\"}}", volume])
            guard volumeOwner == document.owner else { throw ContainerPaneError.refused("The login volume belongs to another owner; it was left unchanged.") }
            // The bounded home initializer is owned too: a timeout must leave
            // an exact container ID that Status Center can stop, not a lost run.
            var initializer = ContainerPaneRecord(id: owner + "-home", paneID: pane.id, generation: pane.launchGeneration,
                configuration: configuration, volume: volume, runtime: runtime, containerID: nil, removed: false, createdAt: Date())
            document.records.append(initializer)
            try save(document)
            let initializerCID = directory.appendingPathComponent("container-\(initializer.id).cid")
            let initializerID = try checked(configuration, ["create", "--rm", "--name", "parley-\(initializer.id)", "--cidfile", initializerCID.path,
                "--label", "\(ContainerLaunchProjection.ownerLabel)=\(initializer.id)",
                "--label", "\(ContainerLaunchProjection.runtimeLabel)=\(runtime)",
                "--log-driver=none", "--network=none", "--user", "0:0", "--cap-drop=ALL", "--cap-add=CHOWN",
                "--security-opt=no-new-privileges=true", "--mount", "type=volume,source=\(volume),target=\(ContainerLaunchProjection.home)",
                "--entrypoint", "/bin/chown", configuration.imageID, "\(getuid()):\(getgid())", ContainerLaunchProjection.home])
            guard ContainerLaunchProjection.isHex(initializerID, length: 64) else { throw ContainerPaneError.refused("The home initializer has no valid container receipt.") }
            initializer.containerID = initializerID
            document.records[document.records.count - 1] = initializer
            try save(document)
            _ = try checked(configuration, ["start", "--attach", initializerID])
            try remove(initializer)
            document = try read()
            document.records.removeAll { $0.id == initializer.id }
            try save(document)
            let cidFile = directory.appendingPathComponent("container-\(owner).cid")
            argv.insert(contentsOf: ["--cidfile", cidFile.path], at: 3)
            let result = try run(configuration.dockerExecutable, argv, token: token)
            let id = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, ContainerLaunchProjection.isHex(id, length: 64) else {
                let detail = String(result.stderrText.replacingOccurrences(of: token, with: "<pane capability>").prefix(1200))
                throw ContainerPaneError.refused("Container creation was not confirmed. Its intent and any creation receipt were kept in Status Center; do not retry blindly. \(detail)")
            }
            guard let index = document.records.firstIndex(where: { $0.id == owner }) else { throw ContainerPaneError.refused("The creation intent disappeared.") }
            document.records[index].containerID = id
            try save(document)
            guard try verifiedContainerID(document.records[index]) == id else {
                throw ContainerPaneError.refused("The created container disappeared before attach; its receipt remains in Status Center.")
            }
            return id
        }
    }

    private func verifiedContainerID(_ record: ContainerPaneRecord) throws -> String? {
        try verifyDaemon(record.configuration)
        let cidFile = directory.appendingPathComponent("container-\(record.id).cid")
        let id: String
        if let recorded = record.containerID { id = recorded }
        else if FileManager.default.fileExists(atPath: cidFile.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: cidFile.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 128 else {
                throw ContainerPaneError.refused("The container creation receipt is unsafe.")
            }
            id = try String(contentsOf: cidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let candidates = try checked(record.configuration, ["container", "ls", "--all", "--filter", "label=\(ContainerLaunchProjection.ownerLabel)=\(record.id)", "--format", "{{.ID}}"])
            if candidates.isEmpty { return nil }
            throw ContainerPaneError.refused("No container ID was recorded. Inspect the Docker runtime manually; labels alone do not grant cleanup authority.")
        }
        guard ContainerLaunchProjection.isHex(id, length: 64) else { throw ContainerPaneError.refused("Invalid container creation receipt.") }
        let listed = try checked(record.configuration, ["container", "ls", "--all", "--no-trunc", "--filter", "id=\(id)", "--format", "{{.ID}}"])
        if listed.isEmpty { return nil }
        guard listed == id else { throw ContainerPaneError.refused("The container identity is ambiguous.") }
        let owner = try checked(record.configuration, ["container", "inspect", "--format", "{{index .Config.Labels \"com.parley.owner\"}}", id])
        guard owner == record.id else { throw ContainerPaneError.refused("The container ownership marker changed; it was left alone.") }
        return id
    }

    public func stop(paneID: String, generation: Int? = nil) throws {
        try lock.withLock {
            let records = try read().records.filter { $0.paneID == paneID && !$0.removed && (generation == nil || $0.generation == generation) }
            for record in records { try remove(record) }
        }
    }

    public func stopAll() throws {
        let records = try records().filter { !$0.removed }
        var failures: [String] = []
        for record in records { do { try remove(record) } catch { failures.append(error.localizedDescription) } }
        if !failures.isEmpty { throw ContainerPaneError.refused(failures.joined(separator: "\n")) }
    }

    public func remove(_ reviewed: ContainerPaneRecord) throws {
        try lock.withLock {
            var document = try read()
            guard let index = document.records.firstIndex(where: { $0 == reviewed }) else { throw ContainerPaneError.refused("The container record changed; refresh it before cleanup.") }
            if !reviewed.removed, let id = try verifiedContainerID(reviewed) {
                let running = try checked(reviewed.configuration, ["container", "inspect", "--format", "{{.State.Running}}", id])
                if running == "true" { _ = try checked(reviewed.configuration, ["container", "stop", "--time", "5", id]) }
                if try verifiedContainerID(reviewed) != nil { _ = try checked(reviewed.configuration, ["container", "rm", id]) }
                guard try verifiedContainerID(reviewed) == nil else { throw ContainerPaneError.refused("Docker did not confirm removal; the pane is still owned.") }
            }
            document.records[index].removed = true
            if reviewed.volume.isEmpty { document.records.remove(at: index) }
            try save(document)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("container-\(reviewed.id).cid"))
        }
    }

    private func sameHome(_ left: ContainerPaneRecord, _ right: ContainerPaneRecord) -> Bool {
        left.volume == right.volume && left.configuration.daemonID == right.configuration.daemonID
            && left.configuration.daemonEndpoint == right.configuration.daemonEndpoint
    }

    public func deleteLoginState(_ reviewed: ContainerPaneRecord) throws {
        try lock.withLock {
            var document = try read()
            guard document.records.contains(reviewed), document.records.filter({ sameHome($0, reviewed) }).allSatisfy(\.removed) else {
                throw ContainerPaneError.refused("Stop and remove every container using this login state first.")
            }
            try verifyDaemon(reviewed.configuration)
            let used = try checked(reviewed.configuration, ["container", "ls", "--all", "--filter", "volume=\(reviewed.volume)", "--format", "{{.ID}}"])
            guard used.isEmpty else { throw ContainerPaneError.refused("A container still references this login volume.") }
            let existing = try checked(reviewed.configuration, ["volume", "ls", "--filter", "name=^\(reviewed.volume)$", "--format", "{{.Name}}"])
            if !existing.isEmpty {
            let owner = try checked(reviewed.configuration, ["volume", "inspect", "--format", "{{index .Labels \"com.parley.volume-owner\"}}", reviewed.volume])
            guard owner == document.owner else { throw ContainerPaneError.refused("The volume ownership changed; it was left alone.") }
            _ = try checked(reviewed.configuration, ["volume", "rm", reviewed.volume])
            }
            document.records.removeAll { sameHome($0, reviewed) }
            try save(document)
        }
    }
}
