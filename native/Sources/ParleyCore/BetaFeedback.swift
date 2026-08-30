import Foundation

public struct BetaFeedbackBuild: Codable, Equatable, Sendable {
    public let applicationVersion: String
    public let buildNumber: String
    public let sourceCommit: String?
    public let runtime: String

    public init(
        applicationVersion: String,
        buildNumber: String,
        sourceCommit: String?,
        runtime: String
    ) {
        self.applicationVersion = applicationVersion
        self.buildNumber = buildNumber
        self.sourceCommit = sourceCommit
        self.runtime = runtime
    }
}

public struct BetaFeedbackVendor: Codable, Equatable, Sendable {
    public let vendor: PaneKind
    public let installed: Bool
    public let version: String?
    public let state: VendorCompatibilityState
    public let versionChanged: Bool
    public let capabilities: [VendorCompatibilityCapabilityResult]
}

public struct BetaFeedbackManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let build: BetaFeedbackBuild
    public let updateChannel: UpdateChannel
    public let compatibilityCheckedAt: Date
    public let vendors: [BetaFeedbackVendor]
    public let includedFiles: [String]
    public let excludedByDesign: [String]
}

public struct BetaFeedbackBundle: Equatable, Sendable {
    public let manifest: BetaFeedbackManifest
    public let diagnostics: DiagnosticsReport

    public var requiresExplicitReview: Bool { true }
}

public enum BetaFeedbackBundleBuilder {
    public static let schemaVersion = 1

    public static func build(
        generatedAt: Date = Date(),
        build: BetaFeedbackBuild,
        updateChannel: UpdateChannel,
        compatibility: VendorCompatibilitySnapshot,
        diagnostics: DiagnosticsReport
    ) -> BetaFeedbackBundle {
        let safeBuild = BetaFeedbackBuild(
            applicationVersion: safeBuildValue(build.applicationVersion, fallback: "unknown"),
            buildNumber: safeBuildValue(build.buildNumber, fallback: "unknown"),
            sourceCommit: build.sourceCommit.flatMap { commit in
                commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) == nil ? nil : commit
            },
            runtime: ["production", "development"].contains(build.runtime)
                ? build.runtime
                : "unknown"
        )
        let vendors = compatibility.vendors.map { result in
            BetaFeedbackVendor(
                vendor: result.vendor,
                installed: result.installed,
                version: result.version.flatMap { VendorCompatibilityChecker.semanticVersion(in: $0) },
                state: result.state,
                versionChanged: result.versionChanged,
                capabilities: result.capabilities
            )
        }
        let manifest = BetaFeedbackManifest(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            build: safeBuild,
            updateChannel: updateChannel,
            compatibilityCheckedAt: compatibility.checkedAt,
            vendors: vendors,
            includedFiles: ["feedback.json", "diagnostics.json", "README.txt"],
            excludedByDesign: [
                "prompts, questions, delegated instructions, answers and result bodies",
                "terminal contents, selections, titles, commands and working folders",
                "pane and workspace display names",
                "credentials, tokens, socket paths, raw journals and raw logs",
                "vendor authentication data, browser profiles and subscription details",
            ]
        )
        return BetaFeedbackBundle(manifest: manifest, diagnostics: diagnostics)
    }

    private static func safeBuildValue(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 128,
              trimmed.range(of: #"^[0-9A-Za-z.+_-]+$"#, options: .regularExpression) != nil else {
            return fallback
        }
        return trimmed
    }

}

public enum BetaFeedbackBundleEncoder {
    public static func encode(_ bundle: BetaFeedbackBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle.manifest)
    }
}

public enum BetaFeedbackArchiveError: LocalizedError, Equatable {
    case invalidDestination
    case archiveFailed(String)
    case archiveMissing

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: "Choose a local .zip destination in an existing folder."
        case let .archiveFailed(detail): "Parley could not create the feedback ZIP: \(detail)"
        case .archiveMissing: "The feedback ZIP command completed without creating an archive."
        }
    }
}

public final class BetaFeedbackArchiveWriter: @unchecked Sendable {
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        runner: any CommandRunning = ProcessCommandRunner(timeout: 30),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func write(bundle: BetaFeedbackBundle, to destination: URL) throws {
        guard destination.isFileURL,
              destination.pathExtension.caseInsensitiveCompare("zip") == .orderedSame,
              !destination.lastPathComponent.isEmpty,
              fileManager.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw BetaFeedbackArchiveError.invalidDestination
        }
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("parley-beta-feedback-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let folder = temporaryRoot.appendingPathComponent("Parley Beta Feedback", isDirectory: true)
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let feedback = folder.appendingPathComponent("feedback.json")
        let diagnostics = folder.appendingPathComponent("diagnostics.json")
        let readme = folder.appendingPathComponent("README.txt")
        try BetaFeedbackBundleEncoder.encode(bundle).write(to: feedback, options: .atomic)
        try DiagnosticsReportEncoder.encode(bundle.diagnostics).write(to: diagnostics, options: .atomic)
        try Data(Self.readme.utf8).write(to: readme, options: .atomic)
        for file in [feedback, diagnostics, readme] {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        let archive = temporaryRoot.appendingPathComponent("Parley-Beta-Feedback.zip")
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", folder.path, archive.path],
            environment: ProcessInfo.processInfo.environment,
            input: nil
        )
        guard output.status == 0 else {
            let detail = (output.stderrText + "\n" + output.stdoutText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BetaFeedbackArchiveError.archiveFailed(
                detail.isEmpty ? "ditto exited with status \(output.status)." : detail
            )
        }
        guard fileManager.fileExists(atPath: archive.path) else {
            throw BetaFeedbackArchiveError.archiveMissing
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: archive)
        } else {
            try fileManager.moveItem(at: archive, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public static let readme = """
    Parley beta feedback bundle

    This local archive was created only after a person opened the review sheet
    and chose Export. Nothing was uploaded automatically.

    Included:
    - build number, application version, source commit and selected update channel
    - installed vendor semantic versions and quota-free compatibility outcomes
    - Parley's structurally redacted diagnostics report

    Excluded by design:
    - prompts, questions, delegated instructions, answers and result bodies
    - terminal contents, selections, titles, commands and working folders
    - pane and workspace display names
    - credentials, tokens, socket paths, raw journals and raw logs
    - vendor authentication data, browser profiles and subscription details

    Review all three files before sharing this ZIP. Parley does not upload it.
    """
}
