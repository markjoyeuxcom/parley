import Darwin
import CryptoKit
import Foundation
import ImageIO

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

public enum ContextPackSourceKind: String, CaseIterable, Codable, Equatable, Sendable {
    case file
    case gitDiff
    case visibleTerminal
    case commandResult
    case agentFileDraft
    case workspaceBrief
    case pinnedSnippet
    case editorSelection
    case editorDiagnostics
    case browserURL
    case browserSelection
    case browserScreenshot
    case toolArtifact

    public var label: String {
        switch self {
        case .file: "Selected file"
        case .gitDiff: "Git diff"
        case .visibleTerminal: "Terminal selection"
        case .commandResult: "Command result"
        case .agentFileDraft: "Agent-provided file draft"
        case .workspaceBrief: "Workspace brief"
        case .pinnedSnippet: "Pinned snippet"
        case .editorSelection: "Editor selection"
        case .editorDiagnostics: "Editor diagnostics"
        case .browserURL: "Browser URL"
        case .browserSelection: "Browser selected text"
        case .browserScreenshot: "Browser screenshot"
        case .toolArtifact: "Saved tool artifact"
        }
    }
}

public struct ContextPackSource: Codable, Equatable, Sendable {
    public let kind: ContextPackSourceKind
    public let label: String
    public let detail: String
    public let referenceID: String?
    public let vendorEvidence: VendorToolEvidenceProvenance?

    public init(
        kind: ContextPackSourceKind,
        label: String,
        detail: String,
        referenceID: String? = nil,
        vendorEvidence: VendorToolEvidenceProvenance? = nil
    ) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.referenceID = referenceID
        self.vendorEvidence = vendorEvidence
    }
}

public struct ContextPackPart: Identifiable, Codable, Equatable, Sendable {
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

public struct ContextPack: Identifiable, Codable, Equatable, Sendable {
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

public struct ContextPackMeasurement: Equatable, Sendable {
    public let renderedByteCount: Int
    public let isValid: Bool

    public init(renderedByteCount: Int, isValid: Bool) {
        self.renderedByteCount = renderedByteCount
        self.isValid = isValid
    }
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
    case artifactTooLarge
    case notText
    case invalidEvidence(String)
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
        case .artifactTooLarge:
            "That saved browser/tool artifact is too large to inspect safely. Select an artifact no larger than 25 MB."
        case .notText:
            "Context packs can contain UTF-8 text only."
        case let .invalidEvidence(detail):
            detail
        case let .commandFailed(detail):
            detail
        }
    }
}

public enum ContextPackGitDiffScope: Equatable, Sendable {
    case combined
    case workingTree
    case staged
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
/// person can inspect before sending. Person-created drafts remain ephemeral;
/// an agent-proposed pack may be serialized only as part of its durable,
/// human-reviewed checkpoint. Durable workspace briefs and reusable pinned
/// snippets enter only through explicit snapshots.
public final class ContextPackBuilder: @unchecked Sendable {
    public static let defaultMaximumPartBytes = 60_000
    public static let defaultMaximumRenderedBytes = 90_000
    public static let defaultMaximumArtifactBytes = 25 * 1_024 * 1_024
    public static let maximumParts = 16

    public let maximumPartBytes: Int
    public let maximumRenderedBytes: Int
    public let maximumArtifactBytes: Int

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
        maximumArtifactBytes: Int = ContextPackBuilder.defaultMaximumArtifactBytes,
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
        self.maximumArtifactBytes = max(1, maximumArtifactBytes)
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
        try gitDiff(in: folder, scope: .combined, relativeFile: nil)
    }

    /// Recaptures a fixed Git surface from disk. An optional relative file is
    /// passed only after `--`, never interpreted by a shell or as a Git option.
    public func gitDiff(
        in folder: String,
        scope: ContextPackGitDiffScope,
        relativeFile: String? = nil
    ) throws -> ContextPackPart {
        try requireDirectory(folder)
        let root = try git(in: folder, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw ContextPackError.commandFailed("git returned no repository root") }
        let captureFolder = relativeFile == nil ? root : folder
        let pathspec = relativeFile.map { ["--", $0] } ?? ["--"]
        let status = try git(in: captureFolder, ["status", "--short", "--untracked-files=all"] + pathspec)
            .trimmingCharacters(in: .newlines)
        let staged: String
        let working: String
        switch scope {
        case .combined:
            staged = try git(
                in: captureFolder,
                ["diff", "--cached", "--no-ext-diff", "--no-color"] + pathspec
            ).trimmingCharacters(in: .newlines)
            working = try git(
                in: captureFolder,
                ["diff", "--no-ext-diff", "--no-color"] + pathspec
            ).trimmingCharacters(in: .newlines)
        case .workingTree:
            staged = ""
            working = try git(
                in: captureFolder,
                ["diff", "--no-ext-diff", "--no-color"] + pathspec
            ).trimmingCharacters(in: .newlines)
        case .staged:
            staged = try git(
                in: captureFolder,
                ["diff", "--cached", "--no-ext-diff", "--no-color"] + pathspec
            ).trimmingCharacters(in: .newlines)
            working = ""
        }

        let containsUntracked = status.split(separator: "\n").contains { $0.hasPrefix("??") }
        let hasChanges = switch scope {
        case .combined: !status.isEmpty || !staged.isEmpty || !working.isEmpty
        case .workingTree: !working.isEmpty || containsUntracked
        case .staged: !staged.isEmpty
        }
        guard hasChanges else { throw ContextPackError.noChanges }

        let selected = relativeFile.map { " for \($0)" } ?? ""
        let content = switch scope {
        case .combined:
            """
            Git status\(selected):
            \(status.isEmpty ? "(clean outside the included diffs)" : status)

            Staged diff:
            \(staged.isEmpty ? "(none)" : staged)

            Working-tree diff:
            \(working.isEmpty ? "(none)" : working)

            Untracked files are named by status only. Their contents were not read.
            """
        case .workingTree:
            """
            Git status\(selected):
            \(status.isEmpty ? "(none)" : status)

            Working-tree diff:
            \(working.isEmpty ? "(none; untracked files are named by status only)" : working)
            """
        case .staged:
            """
            Git status\(selected):
            \(status.isEmpty ? "(none)" : status)

            Staged diff:
            \(staged)
            """
        }
        let label = switch scope {
        case .combined: "Current Git changes"
        case .workingTree: "Working-tree Git changes"
        case .staged: "Staged Git changes"
        }
        let detail = relativeFile.map { "\(root) · \($0)" } ?? root
        return try part(
            source: ContextPackSource(kind: .gitDiff, label: label, detail: detail),
            text: content
        )
    }

    public func terminalSelection(paneID: String, paneName: String, text: String) throws -> ContextPackPart {
        try part(
            source: ContextPackSource(
                kind: .visibleTerminal,
                label: paneName,
                detail: "Selected terminal text from \(paneName) (\(paneID))"
            ),
            text: text
        )
    }

    public func editorSelection(
        relativeFile: String,
        startLine: Int,
        endLine: Int,
        text: String
    ) throws -> ContextPackPart {
        let range = startLine == endLine ? "\(startLine)" : "\(startLine)-\(endLine)"
        return try part(
            source: ContextPackSource(
                kind: .editorSelection,
                label: "VS Code selection",
                detail: "\(relativeFile):\(range)"
            ),
            text: text
        )
    }

    public func editorDiagnostics(relativeFile: String, text: String) throws -> ContextPackPart {
        try part(
            source: ContextPackSource(
                kind: .editorDiagnostics,
                label: "VS Code diagnostics",
                detail: relativeFile
            ),
            text: text
        )
    }

    public func browserURLEvidence(
        from pane: WorkbenchPane,
        url: String,
        capturedAt: Date = Date()
    ) throws -> ContextPackPart {
        let capability = try evidenceCapability(for: pane)
        let webURL = try validWebURL(url)
        let provenance = evidenceProvenance(
            kind: .browserURL,
            pane: pane,
            capability: capability,
            sourceURL: webURL,
            capturedAt: capturedAt,
            captureBasis: .personProvidedURL
        )
        return try part(
            source: ContextPackSource(
                kind: .browserURL,
                label: URL(string: webURL)?.host ?? "Web page",
                detail: "Person-provided URL attributed to \(pane.displayName) (\(pane.id))",
                vendorEvidence: provenance
            ),
            text: "Person-selected web URL: \(webURL)\nParley did not fetch or verify this page."
        )
    }

    public func browserSelectionEvidence(
        from pane: WorkbenchPane,
        url: String,
        text: String,
        capturedAt: Date = Date()
    ) throws -> ContextPackPart {
        let capability = try evidenceCapability(for: pane)
        let webURL = try validWebURL(url)
        let selected = ContextPackText.normalize(text)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextPackError.invalidEvidence("Paste the exact selected browser text before adding this evidence.")
        }
        let provenance = evidenceProvenance(
            kind: .browserSelection,
            pane: pane,
            capability: capability,
            sourceURL: webURL,
            capturedAt: capturedAt,
            captureBasis: .personProvidedSelection
        )
        return try part(
            source: ContextPackSource(
                kind: .browserSelection,
                label: URL(string: webURL)?.host ?? "Web selection",
                detail: "Person-provided selection attributed to \(pane.displayName) (\(pane.id))",
                vendorEvidence: provenance
            ),
            text: selected
        )
    }

    public func vendorArtifactEvidence(
        kind: VendorToolEvidenceKind,
        from pane: WorkbenchPane,
        file: URL,
        sourceURL: String?,
        capturedAt: Date = Date()
    ) throws -> ContextPackPart {
        guard kind == .browserScreenshot || kind == .savedArtifact else {
            throw ContextPackError.invalidEvidence("Choose Browser screenshot or Saved tool artifact for a local file.")
        }
        let capability = try evidenceCapability(for: pane)
        let selected = file.standardizedFileURL
        let values = try selected.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ContextPackError.invalidEvidence("The selected browser/tool artifact is not a regular file: \(selected.path)")
        }
        guard let measuredSize = values.fileSize, measuredSize <= maximumArtifactBytes else {
            throw ContextPackError.artifactTooLarge
        }
        let data = try Data(contentsOf: selected, options: .mappedIfSafe)
        guard data.count <= maximumArtifactBytes else { throw ContextPackError.artifactTooLarge }
        if kind == .browserScreenshot, CGImageSourceCreateWithData(data as CFData, nil) == nil {
            throw ContextPackError.invalidEvidence("The selected screenshot is not a readable image file.")
        }
        let webURL = try sourceURL.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : try validWebURL(trimmed)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let provenance = evidenceProvenance(
            kind: kind,
            pane: pane,
            capability: capability,
            sourceURL: webURL,
            artifactPath: selected.path,
            artifactByteCount: data.count,
            sha256: digest,
            capturedAt: capturedAt,
            captureBasis: .parleyInspectedLocalArtifact
        )
        let sourceKind: ContextPackSourceKind = kind == .browserScreenshot ? .browserScreenshot : .toolArtifact
        return try part(
            source: ContextPackSource(
                kind: sourceKind,
                label: selected.lastPathComponent,
                detail: "Person-selected local \(kind.label.lowercased()) attributed to \(pane.displayName) (\(pane.id))",
                vendorEvidence: provenance
            ),
            text: "Local file selected by the person: \(selected.path)\nThe file bytes are not embedded in this text context pack. The receiving vendor must say if its own tools or granted filesystem scope cannot read that path."
        )
    }

    public func workspaceBrief(_ brief: WorkspaceBrief) throws -> ContextPackPart {
        try part(
            source: ContextPackSource(
                kind: .workspaceBrief,
                label: brief.workspaceName,
                detail: "Workspace brief for \(brief.workspaceName) (\(brief.workspaceID)), saved \(brief.updatedAt.formatted(.iso8601))",
                referenceID: brief.id
            ),
            text: brief.renderedText
        )
    }

    public func pinnedSnippet(_ snippet: PinnedContextSnippet) throws -> ContextPackPart {
        try part(
            source: ContextPackSource(
                kind: .pinnedSnippet,
                label: snippet.title,
                detail: "Pinned snippet \(snippet.title) (\(snippet.id)), saved \(snippet.updatedAt.formatted(.iso8601))",
                referenceID: snippet.id
            ),
            text: snippet.text
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
        let rendered = renderUnchecked(pack)
        try validate(pack, rendered: rendered)
        return rendered
    }

    public func measure(_ pack: ContextPack) -> ContextPackMeasurement {
        let rendered = renderUnchecked(pack)
        return ContextPackMeasurement(
            renderedByteCount: rendered.utf8.count,
            isValid: (try? validate(pack, rendered: rendered)) != nil
        )
    }

    public func renderedByteCount(_ pack: ContextPack) -> Int {
        measure(pack).renderedByteCount
    }

    private func validate(_ pack: ContextPack, rendered: String) throws {
        guard !pack.parts.isEmpty else { throw ContextPackError.noParts }
        guard pack.parts.count <= Self.maximumParts else { throw ContextPackError.tooManyParts }
        for part in pack.parts {
            guard !part.text.isEmpty else { throw ContextPackError.emptyPart }
            guard part.byteCount <= maximumPartBytes else { throw ContextPackError.partTooLarge }
        }
        guard rendered.utf8.count <= maximumRenderedBytes else { throw ContextPackError.packTooLarge }
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
        if !note.isEmpty { sections.append("Request for the receiving vendor:\n\(note)") }
        for (index, part) in pack.parts.enumerated() {
            var metadata = [
                "Context part \(index + 1) of \(pack.parts.count)",
                "Type: \(part.source.kind.label)",
                "Source: \(part.source.detail)",
                "Captured UTF-8 bytes: \(part.capturedByteCount)",
                "Current UTF-8 bytes: \(part.byteCount)",
                "Edited after capture: \(part.isEdited ? "yes" : "no")",
            ]
            if let evidence = part.source.vendorEvidence {
                metadata.append(contentsOf: [
                    "Evidence vendor: \(evidence.vendor.label)",
                    "Evidence pane: \(evidence.paneName) (\(evidence.paneID))",
                    "Browser/tool capability: \(evidence.toolAccess.label)",
                    "Capability basis: \(evidence.toolAccessDetail)",
                    "Attribution basis: \(evidence.captureBasis.detail)",
                    "Parley browser boundary: Parley did not open, scrape or control the vendor browser session.",
                ])
                if let sourceURL = evidence.sourceURL { metadata.append("Evidence URL: \(sourceURL)") }
                if let artifactPath = evidence.artifactPath { metadata.append("Local artifact: \(artifactPath)") }
                if let bytes = evidence.artifactByteCount { metadata.append("Artifact bytes: \(bytes)") }
                if let sha256 = evidence.sha256 { metadata.append("Artifact SHA-256: \(sha256)") }
                metadata.append("Evidence captured: \(evidence.capturedAt.formatted(.iso8601))")
            }
            sections.append("""
            \(metadata.joined(separator: "\n"))

            --- begin explicit context ---
            \(part.text)
            --- end explicit context ---
            """)
        }
        return ContextPackText.normalize(sections.joined(separator: "\n\n"))
    }

    private func evidenceCapability(for pane: WorkbenchPane) throws -> PaneToolCapabilitySummary {
        let capability = PaneToolCapabilityProjection.summary(for: pane, profiles: [])
        guard capability.canCaptureEvidence else {
            throw ContextPackError.invalidEvidence(capability.detail)
        }
        return capability
    }

    private func evidenceProvenance(
        kind: VendorToolEvidenceKind,
        pane: WorkbenchPane,
        capability: PaneToolCapabilitySummary,
        sourceURL: String?,
        artifactPath: String? = nil,
        artifactByteCount: Int? = nil,
        sha256: String? = nil,
        capturedAt: Date,
        captureBasis: VendorToolEvidenceCaptureBasis
    ) -> VendorToolEvidenceProvenance {
        VendorToolEvidenceProvenance(
            kind: kind,
            vendor: pane.kind,
            paneID: pane.id,
            paneName: pane.displayName,
            sourceURL: sourceURL,
            artifactPath: artifactPath,
            artifactByteCount: artifactByteCount,
            sha256: sha256,
            capturedAt: capturedAt,
            captureBasis: captureBasis,
            toolAccess: capability.toolAccess,
            toolAccessDetail: capability.detail
        )
    }

    private func validWebURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 8_192,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw ContextPackError.invalidEvidence("Evidence URLs must be credential-free HTTP or HTTPS URLs.")
        }
        return url.absoluteString
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
