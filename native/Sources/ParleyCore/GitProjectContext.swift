import Foundation

public struct GitProjectContext: Equatable, Sendable {
    public let branch: String
    public let isDirty: Bool

    public init(branch: String, isDirty: Bool) {
        self.branch = branch
        self.isDirty = isDirty
    }
}

/// Reads the small piece of repository state Parley owns in its pane chrome.
/// Every folder costs one fixed argv-based Git command with a hard process
/// timeout; no shell, pager, hook, index lock or unbounded file read is used.
public struct GitProjectContextResolver: Sendable {
    private let gitExecutable: URL
    private let environment: [String: String]
    private let timeout: TimeInterval

    public init(
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 2
    ) {
        self.gitExecutable = gitExecutable
        var gitEnvironment = environment
        gitEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        gitEnvironment["GIT_PAGER"] = "cat"
        gitEnvironment["PAGER"] = "cat"
        gitEnvironment["LC_ALL"] = "C"
        self.environment = gitEnvironment
        self.timeout = max(0.1, timeout)
    }

    public func contexts(for folders: Set<String>) -> [String: GitProjectContext] {
        var contexts: [String: GitProjectContext] = [:]
        for folder in folders.sorted() {
            let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
            if let context = context(in: standardized) {
                contexts[standardized] = context
            }
        }
        return contexts
    }

    public func context(in folder: String) -> GitProjectContext? {
        let output: CommandOutput
        do {
            output = try ProcessCommandRunner(timeout: timeout).run(
                executable: gitExecutable,
                arguments: [
                    "-C", folder,
                    "-c", "core.fsmonitor=false",
                    "status", "--porcelain=v2", "--branch", "--untracked-files=normal",
                ],
                environment: environment,
                input: nil
            )
        } catch {
            return nil
        }
        guard output.status == 0 else { return nil }
        return Self.parseStatus(output.stdoutText)
    }

    public static func parseStatus(_ text: String) -> GitProjectContext? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return nil }

        let headPrefix = "# branch.head "
        let oidPrefix = "# branch.oid "
        let head = lines.first(where: { $0.hasPrefix(headPrefix) })
            .map { String($0.dropFirst(headPrefix.count)) }
        let oid = lines.first(where: { $0.hasPrefix(oidPrefix) })
            .map { String($0.dropFirst(oidPrefix.count)) }

        let branch: String
        if let head, head != "(detached)", !head.isEmpty {
            branch = head
        } else if let oid, oid != "(initial)", !oid.isEmpty {
            branch = "@" + oid.prefix(8)
        } else {
            return nil
        }

        let isDirty = lines.contains { !$0.hasPrefix("# ") }
        return GitProjectContext(branch: branch, isDirty: isDirty)
    }
}
