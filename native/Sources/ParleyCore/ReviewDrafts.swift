import Foundation

public struct ReviewDraft: Equatable, Sendable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

public enum ReviewDraftError: LocalizedError, Equatable {
    case invalidFolder(String)
    case invalidFile(String)
    case noChanges
    case contentTooLarge
    case notText
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidFolder(path):
            "The review folder does not exist: \(path)"
        case let .invalidFile(path):
            "The selected review file is unavailable: \(path)"
        case .noChanges:
            "Git reports no staged, unstaged or untracked changes in this repository."
        case .contentTooLarge:
            "That review is too large to send safely in one Parley handoff. Narrow the change or select a smaller file."
        case .notText:
            "Parley can preview and send text files only."
        case let .commandFailed(detail):
            "Git could not prepare the review:\n\(detail)"
        }
    }
}

/// Produces editable review prompts without a shell, hooks, pagers or optional
/// index locks. The resulting handoff is bounded before it reaches tmux.
public final class ReviewDraftBuilder {
    public static let defaultMaximumBytes = 160_000

    private let gitExecutable: URL
    private let environment: [String: String]
    private let runner: any CommandRunning
    private let maximumBytes: Int
    private let fileManager: FileManager

    public init(
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any CommandRunning = ProcessCommandRunner(timeout: 5),
        maximumBytes: Int = ReviewDraftBuilder.defaultMaximumBytes,
        fileManager: FileManager = .default
    ) {
        self.gitExecutable = gitExecutable
        var reviewEnvironment = environment
        reviewEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        reviewEnvironment["GIT_PAGER"] = "cat"
        reviewEnvironment["PAGER"] = "cat"
        reviewEnvironment["LC_ALL"] = "C"
        self.environment = reviewEnvironment
        self.runner = runner
        self.maximumBytes = max(1, maximumBytes)
        self.fileManager = fileManager
    }

    public func changes(in folder: String) throws -> ReviewDraft {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReviewDraftError.invalidFolder(folder)
        }

        let root = try git(in: folder, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw ReviewDraftError.commandFailed("git returned no repository root")
        }
        let status = try git(in: root, ["status", "--short", "--untracked-files=all"])
            .trimmingCharacters(in: .newlines)
        let staged = try git(in: root, ["diff", "--cached", "--no-ext-diff", "--no-color", "--"])
            .trimmingCharacters(in: .newlines)
        let working = try git(in: root, ["diff", "--no-ext-diff", "--no-color", "--"])
            .trimmingCharacters(in: .newlines)
        guard !status.isEmpty || !staged.isEmpty || !working.isEmpty else {
            throw ReviewDraftError.noChanges
        }

        let text = """
        Review the current repository changes below. Prioritize correctness bugs,
        security risks, regressions and missing tests. Rank concrete findings by
        severity and cite file:line where possible. If there are no findings, say
        so explicitly. Do not modify files.

        Repository: \(root)

        Git status:
        ```text
        \(status.isEmpty ? "(clean outside the included diffs)" : status)
        ```

        Staged diff:
        ```diff
        \(staged.isEmpty ? "(none)" : staged)
        ```

        Working-tree diff:
        ```diff
        \(working.isEmpty ? "(none)" : working)
        ```

        Untracked files are named in Git status but their contents are not
        silently read. Inspect them from the repository only if your permissions
        allow it and they are relevant to the review.
        """
        try requireBounded(text)
        return ReviewDraft(title: "Review repository changes", text: text)
    }

    public func file(at file: URL) throws -> ReviewDraft {
        let selected = file.standardizedFileURL
        guard fileManager.fileExists(atPath: selected.path) else {
            throw ReviewDraftError.invalidFile(selected.path)
        }
        let values = try selected.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ReviewDraftError.invalidFile(selected.path)
        }
        if let size = values.fileSize, size > maximumBytes {
            throw ReviewDraftError.contentTooLarge
        }

        let handle = try FileHandle(forReadingFrom: selected)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ReviewDraftError.contentTooLarge }
        guard !data.contains(0), let content = String(data: data, encoding: .utf8) else {
            throw ReviewDraftError.notText
        }

        let text = """
        Review the selected plan or file below. Prioritize correctness,
        feasibility, missing decisions, hidden risks and test gaps. Rank concrete
        findings by severity and cite line numbers where possible. If it is sound,
        say so explicitly. Do not modify files.

        File: \(selected.path)

        ```text
        \(content)
        ```
        """
        try requireBounded(text)
        return ReviewDraft(title: "Review \(selected.lastPathComponent)", text: text)
    }

    private func git(in folder: String, _ arguments: [String]) throws -> String {
        let output = try runner.run(
            executable: gitExecutable,
            arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments,
            environment: environment,
            input: nil
        )
        guard output.status == 0 else {
            let stdout = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            throw ReviewDraftError.commandFailed(detail.isEmpty ? "git exited with status \(output.status)" : detail)
        }
        return output.stdoutText
    }

    private func requireBounded(_ text: String) throws {
        guard text.utf8.count <= maximumBytes else { throw ReviewDraftError.contentTooLarge }
    }
}
