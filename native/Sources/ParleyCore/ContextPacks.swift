import Darwin
import Foundation

public enum ContextPackText {
    /// Normalizes only transport controls. Unlike terminal relay cleaning it
    /// preserves indentation, repeated blank lines and printable Unicode
    /// because those are source material in files, diffs and command output.
    public static func normalize(_ input: String) -> String {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safeScalars = normalized.unicodeScalars.filter { scalar in
            let value = scalar.value
            if scalar == "\n" || scalar == "\t" { return true }
            return value >= 0x20 && value != 0x7f && !(0x80...0x9f).contains(value)
        }
        return String(String.UnicodeScalarView(safeScalars))
    }
}

public enum ContextPackSourceKind: String, CaseIterable, Equatable, Sendable {
    case file
    case gitDiff
    case visibleTerminal
    case commandResult

    public var label: String {
        switch self {
        case .file: "Selected file"
        case .gitDiff: "Git diff"
        case .visibleTerminal: "Visible terminal"
        case .commandResult: "Command result"
        }
    }
}

public struct ContextPackSource: Equatable, Sendable {
    public let kind: ContextPackSourceKind
    public let label: String
    public let detail: String

    public init(kind: ContextPackSourceKind, label: String, detail: String) {
        self.kind = kind
        self.label = label
        self.detail = detail
    }
}

public struct ContextPackPart: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: ContextPackSource
    public let capturedText: String
    public let text: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        source: ContextPackSource,
        capturedText: String,
        text: String? = nil
    ) {
        self.id = id
        self.source = source
        self.capturedText = ContextPackText.normalize(capturedText)
        self.text = ContextPackText.normalize(text ?? capturedText)
    }

    public var capturedByteCount: Int { capturedText.utf8.count }
    public var byteCount: Int { text.utf8.count }
    public var isEdited: Bool { text != capturedText }

    public func replacingText(_ replacement: String) -> ContextPackPart {
        ContextPackPart(
            id: id,
            source: source,
            capturedText: capturedText,
            text: replacement
        )
    }
}

public struct ContextPack: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var note: String
    public var parts: [ContextPackPart]

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String = "Untitled context",
        note: String = "",
        parts: [ContextPackPart] = []
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.parts = parts
    }

    public var sourceByteCount: Int { parts.reduce(0) { $0 + $1.byteCount } }
}

public enum ContextPackError: LocalizedError, Equatable {
    case invalidFolder(String)
    case invalidFile(String)
    case invalidExecutable(String)
    case noChanges
    case emptyPart
    case noParts
    case tooManyParts
    case partTooLarge
    case packTooLarge
    case notText
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidFolder(path):
            "The context folder does not exist: \(path)"
        case let .invalidFile(path):
            "The selected context file is unavailable: \(path)"
        case let .invalidExecutable(path):
            "Context commands need an absolute executable file. Parley cannot run: \(path)"
        case .noChanges:
            "Git reports no staged, unstaged or untracked changes in this repository."
        case .emptyPart:
            "That source produced no text to add."
        case .noParts:
            "Add at least one explicit source before sending this context pack."
        case .tooManyParts:
            "A context pack accepts at most 16 explicit sources. Remove a part before adding another."
        case .partTooLarge:
            "That source is too large for one context pack. Narrow the file, diff, screen or command output."
        case .packTooLarge:
            "This context pack is too large for one Parley handoff. Remove or shorten one or more parts."
        case .notText:
            "Context packs can contain UTF-8 text only."
        case let .commandFailed(detail):
            detail
        }
    }
}

public protocol ContextCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> CommandOutput
}

/// Executes one exact argv vector in one exact folder. There is deliberately no
/// shell, interpolation, pipe, redirect or glob stage. Both output streams are
/// drained even after their bounded capture fills so a noisy child cannot
/// deadlock while Parley prepares a preview.
public final class ContextProcessCommandRunner: ContextCommandRunning, @unchecked Sendable {
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    public init(timeout: TimeInterval = 15, maximumOutputBytes: Int = 90_001) {
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
    }

    public func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> CommandOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)
        let readers = DispatchGroup()
        let output = BoundedContextData(limit: maximumOutputBytes)
        let errors = BoundedContextData(limit: maximumOutputBytes)

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in finished.signal() }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            output.drain(stdout.fileHandleForReading)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.drain(stderr.fileHandleForReading)
            readers.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            readers.wait()
            throw error
        }

        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        process.waitUntilExit()
        readers.wait()

        var errorData = errors.data
        if timedOut {
            if !errorData.isEmpty { errorData.append(Data("\n".utf8)) }
            errorData.append(Data("Command timed out after \(timeout) seconds".utf8))
        }
        return CommandOutput(
            stdout: output.data,
            stderr: errorData,
            status: timedOut ? 124 : process.terminationStatus
        )
    }
}

private final class BoundedContextData: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data { lock.withLock { storage } }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.readData(ofLength: 8_192)
            if chunk.isEmpty { return }
            lock.withLock {
                let remaining = max(0, limit - storage.count)
                if remaining > 0 { storage.append(chunk.prefix(remaining)) }
            }
        }
    }
}

/// Captures explicit local sources and renders the exact attributed payload a
/// person can inspect before sending. Packs are intentionally ephemeral; saved
/// workspace briefs and reusable snippets are separate roadmap features.
public final class ContextPackBuilder: @unchecked Sendable {
    public static let defaultMaximumPartBytes = 60_000
    public static let defaultMaximumRenderedBytes = 90_000
    public static let maximumParts = 16

    public let maximumPartBytes: Int
    public let maximumRenderedBytes: Int

    private let gitExecutable: URL
    private let environment: [String: String]
    private let gitRunner: any CommandRunning
    private let commandRunner: any ContextCommandRunning
    private let fileManager: FileManager

    public init(
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gitRunner: any CommandRunning = ProcessCommandRunner(timeout: 5),
        commandRunner: (any ContextCommandRunning)? = nil,
        maximumPartBytes: Int = ContextPackBuilder.defaultMaximumPartBytes,
        maximumRenderedBytes: Int = ContextPackBuilder.defaultMaximumRenderedBytes,
        fileManager: FileManager = .default
    ) {
        self.gitExecutable = gitExecutable
        var captureEnvironment = environment
        captureEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        captureEnvironment["GIT_PAGER"] = "cat"
        captureEnvironment["PAGER"] = "cat"
        captureEnvironment["LC_ALL"] = "C"
        self.environment = captureEnvironment
        self.gitRunner = gitRunner
        self.maximumPartBytes = max(1, maximumPartBytes)
        self.maximumRenderedBytes = max(1, maximumRenderedBytes)
        self.commandRunner = commandRunner ?? ContextProcessCommandRunner(
            maximumOutputBytes: max(1, maximumRenderedBytes + 1)
        )
        self.fileManager = fileManager
    }

    public func file(at file: URL) throws -> ContextPackPart {
        let selected = file.standardizedFileURL
        guard fileManager.fileExists(atPath: selected.path) else {
            throw ContextPackError.invalidFile(selected.path)
        }
        let values = try selected.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ContextPackError.invalidFile(selected.path) }
        if let size = values.fileSize, size > maximumPartBytes {
            throw ContextPackError.partTooLarge
        }

        let handle = try FileHandle(forReadingFrom: selected)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumPartBytes + 1) ?? Data()
        guard data.count <= maximumPartBytes else { throw ContextPackError.partTooLarge }
        guard !data.contains(0), let content = String(data: data, encoding: .utf8) else {
            throw ContextPackError.notText
        }
        return try part(
            source: ContextPackSource(
                kind: .file,
                label: selected.lastPathComponent,
                detail: selected.path
            ),
            text: content
        )
    }

    public func gitDiff(in folder: String) throws -> ContextPackPart {
        try requireDirectory(folder)
        let root = try git(in: folder, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw ContextPackError.commandFailed("git returned no repository root") }
        let status = try git(in: root, ["status", "--short", "--untracked-files=all"])
            .trimmingCharacters(in: .newlines)
        let staged = try git(in: root, ["diff", "--cached", "--no-ext-diff", "--no-color", "--"])
            .trimmingCharacters(in: .newlines)
        let working = try git(in: root, ["diff", "--no-ext-diff", "--no-color", "--"])
            .trimmingCharacters(in: .newlines)
        guard !status.isEmpty || !staged.isEmpty || !working.isEmpty else {
            throw ContextPackError.noChanges
        }

        let content = """
        Git status:
        \(status.isEmpty ? "(clean outside the included diffs)" : status)

        Staged diff:
        \(staged.isEmpty ? "(none)" : staged)

        Working-tree diff:
        \(working.isEmpty ? "(none)" : working)

        Untracked files are named by status only. Their contents were not read.
        """
        return try part(
            source: ContextPackSource(kind: .gitDiff, label: "Current Git changes", detail: root),
            text: content
        )
    }

    public func visibleTerminal(paneID: String, paneName: String, text: String) throws -> ContextPackPart {
        try part(
            source: ContextPackSource(
                kind: .visibleTerminal,
                label: paneName,
                detail: "Visible screen from \(paneName) (\(paneID))"
            ),
            text: text
        )
    }

    public func commandResult(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL
    ) throws -> ContextPackPart {
        guard executablePath.hasPrefix("/") else {
            throw ContextPackError.invalidExecutable(executablePath)
        }
        let resolvedExecutable = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard
              fileManager.isExecutableFile(atPath: resolvedExecutable.path) else {
            throw ContextPackError.invalidExecutable(executablePath)
        }
        let directory = workingDirectory.standardizedFileURL
        try requireDirectory(directory.path)

        let output: CommandOutput
        do {
            output = try commandRunner.run(
                executable: resolvedExecutable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment
            )
        } catch {
            throw ContextPackError.commandFailed("The command could not start: \(error.localizedDescription)")
        }
        let content = """
        Exit status: \(output.status)

        Standard output:
        \(output.stdoutText.isEmpty ? "(empty)" : output.stdoutText)

        Standard error:
        \(output.stderrText.isEmpty ? "(empty)" : output.stderrText)
        """
        let argumentDisplay = arguments.map(Self.displayArgument).joined(separator: " ")
        let commandDisplay = argumentDisplay.isEmpty
            ? resolvedExecutable.path
            : "\(resolvedExecutable.path) \(argumentDisplay)"
        return try part(
            source: ContextPackSource(
                kind: .commandResult,
                label: resolvedExecutable.lastPathComponent,
                detail: "\(commandDisplay) · cwd \(directory.path)"
            ),
            text: content
        )
    }

    public func render(_ pack: ContextPack) throws -> String {
        guard !pack.parts.isEmpty else { throw ContextPackError.noParts }
        guard pack.parts.count <= Self.maximumParts else { throw ContextPackError.tooManyParts }
        for part in pack.parts {
            guard !part.text.isEmpty else { throw ContextPackError.emptyPart }
            guard part.byteCount <= maximumPartBytes else { throw ContextPackError.partTooLarge }
        }
        let rendered = renderUnchecked(pack)
        guard rendered.utf8.count <= maximumRenderedBytes else { throw ContextPackError.packTooLarge }
        return rendered
    }

    public func renderedByteCount(_ pack: ContextPack) -> Int {
        renderUnchecked(pack).utf8.count
    }

    private func part(source: ContextPackSource, text: String) throws -> ContextPackPart {
        let result = ContextPackPart(source: source, capturedText: text)
        guard !result.text.isEmpty else { throw ContextPackError.emptyPart }
        guard result.byteCount <= maximumPartBytes else { throw ContextPackError.partTooLarge }
        return result
    }

    private func renderUnchecked(_ pack: ContextPack) -> String {
        let name = ContextPackText.normalize(pack.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = ContextPackText.normalize(pack.note)
        var sections = [
            "Context pack: \(name.isEmpty ? "Untitled context" : name)",
            "This material was explicitly selected by the person using Parley. No hidden terminal history or implicit transcript was included.",
        ]
        if !note.isEmpty { sections.append("Person's note:\n\(note)") }
        for (index, part) in pack.parts.enumerated() {
            sections.append("""
            Context part \(index + 1) of \(pack.parts.count)
            Type: \(part.source.kind.label)
            Source: \(part.source.detail)
            Captured UTF-8 bytes: \(part.capturedByteCount)
            Current UTF-8 bytes: \(part.byteCount)
            Edited after capture: \(part.isEdited ? "yes" : "no")

            --- begin explicit context ---
            \(part.text)
            --- end explicit context ---
            """)
        }
        return ContextPackText.normalize(sections.joined(separator: "\n\n"))
    }

    private func git(in folder: String, _ arguments: [String]) throws -> String {
        let output = try gitRunner.run(
            executable: gitExecutable,
            arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments,
            environment: environment,
            input: nil
        )
        guard output.status == 0 else {
            let stdout = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            throw ContextPackError.commandFailed(
                detail.isEmpty ? "Git exited with status \(output.status)" : detail
            )
        }
        return output.stdoutText
    }

    private func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ContextPackError.invalidFolder(path)
        }
    }

    private static func displayArgument(_ argument: String) -> String {
        if argument.isEmpty { return "\"\"" }
        if argument.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar) || "-._/:".unicodeScalars.contains(scalar)
        }) {
            return argument
        }
        let escaped = argument
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
