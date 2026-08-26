import CryptoKit
import Foundation

public enum UpdateChannel: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case stable
    case beta

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        }
    }

    public var detail: String {
        switch self {
        case .stable: "Published releases that are not marked prerelease."
        case .beta: "The newest published release, including prereleases."
        }
    }
}

public enum ReleaseUpdateState: String, Codable, Equatable, Sendable {
    case available
    case current
    case newerThanChannel
    case unknown
}

public struct GitHubReleaseAsset: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let size: Int
    public let browserDownloadURL: URL

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
    }
}

public struct GitHubRelease: Codable, Equatable, Identifiable, Sendable {
    public let tagName: String
    public let name: String
    public let body: String
    public let draft: Bool
    public let prerelease: Bool
    public let htmlURL: URL
    public let publishedAt: Date
    public let assets: [GitHubReleaseAsset]

    public var id: String { tagName }
    public var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    public func updateState(currentVersion: String) -> ReleaseUpdateState {
        guard let current = ParleySemanticVersion(currentVersion),
              let offered = ParleySemanticVersion(version) else { return .unknown }
        if current < offered { return .available }
        if current == offered { return .current }
        return .newerThanChannel
    }
}

public struct GitHubReleaseCatalog: Equatable, Sendable {
    public static let maximumResponseBytes = 2 * 1_024 * 1_024
    public let releases: [GitHubRelease]

    public static func decode(_ data: Data) throws -> GitHubReleaseCatalog {
        guard data.count <= maximumResponseBytes else { throw ReleaseLifecycleError.responseTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: [GitHubRelease]
        do {
            decoded = try decoder.decode([GitHubRelease].self, from: data)
        } catch {
            throw ReleaseLifecycleError.invalidCatalog
        }
        let releases = try decoded.map { release in
            guard validReleasePage(release.htmlURL),
                  release.assets.allSatisfy({ validDownloadURL($0.browserDownloadURL) }),
                  release.name.utf8.count <= 512,
                  release.body.utf8.count <= 200_000,
                  release.assets.count <= 32,
                  ParleySemanticVersion(release.version) != nil else {
                throw ReleaseLifecycleError.invalidCatalog
            }
            return release
        }
        return GitHubReleaseCatalog(releases: releases)
    }

    public func selected(for channel: UpdateChannel) -> GitHubRelease? {
        releases
            .filter { !$0.draft && (channel == .beta || !$0.prerelease) }
            .max { left, right in
                guard let leftVersion = ParleySemanticVersion(left.version),
                      let rightVersion = ParleySemanticVersion(right.version) else {
                    return left.publishedAt < right.publishedAt
                }
                if leftVersion == rightVersion { return left.publishedAt < right.publishedAt }
                return leftVersion < rightVersion
            }
    }

    public static func validDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.caseInsensitiveCompare("github.com") == .orderedSame
            && url.path.hasPrefix("/markjoyeuxcom/parley/releases/download/")
            && url.user == nil
            && url.password == nil
    }

    private static func validReleasePage(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.caseInsensitiveCompare("github.com") == .orderedSame
            && url.path.hasPrefix("/markjoyeuxcom/parley/releases/")
            && url.user == nil
            && url.password == nil
    }
}

public struct ReleaseArtifactVerification: Codable, Equatable, Sendable {
    public let version: String
    public let dmgName: String
    public let byteCount: Int
    public let sha256: String
    public let downloadURL: URL
    public let releasePageURL: URL
    public let signing: String
    public let notarized: Bool

    public init(
        version: String,
        dmgName: String,
        byteCount: Int,
        sha256: String,
        downloadURL: URL,
        releasePageURL: URL,
        signing: String,
        notarized: Bool
    ) {
        self.version = version
        self.dmgName = dmgName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.releasePageURL = releasePageURL
        self.signing = signing
        self.notarized = notarized
    }

    public var trustLabel: String {
        notarized ? "Developer ID signed and notarized" : "Unnotarized beta artifact"
    }
}

public struct ReleaseCheckResult: Equatable, Sendable {
    public let channel: UpdateChannel
    public let currentVersion: String
    public let release: GitHubRelease
    public let updateState: ReleaseUpdateState
    public let verification: ReleaseArtifactVerification

    public init(
        channel: UpdateChannel,
        currentVersion: String,
        release: GitHubRelease,
        updateState: ReleaseUpdateState,
        verification: ReleaseArtifactVerification
    ) {
        self.channel = channel
        self.currentVersion = currentVersion
        self.release = release
        self.updateState = updateState
        self.verification = verification
    }
}

public enum ReleaseLifecycleError: LocalizedError, Equatable {
    case invalidCatalog
    case responseTooLarge
    case noRelease(UpdateChannel)
    case incompleteRelease
    case invalidMetadata(String)
    case invalidDestination
    case httpStatus(Int)
    case network(String)
    case artifactMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "GitHub returned an invalid Parley release catalog."
        case .responseTooLarge: "GitHub returned release metadata larger than Parley's safety bound."
        case let .noRelease(channel): "No published \(channel.label.lowercased()) release is available."
        case .incompleteRelease: "The release is missing its DMG, release manifest or checksum file."
        case let .invalidMetadata(detail): "The release metadata could not be verified: \(detail)"
        case .invalidDestination: "Choose a local .dmg destination in an existing folder."
        case let .httpStatus(status) where status == 404:
            "GitHub returned HTTP 404. The releases repository may be private; Parley does not use or store GitHub credentials. Open Releases in your signed-in browser, or publish releases from a public repository."
        case let .httpStatus(status) where status == 403:
            "GitHub returned HTTP 403. The public API rate limit may be exhausted; try again later or open Releases in your browser."
        case let .httpStatus(status): "GitHub returned HTTP \(status)."
        case let .network(detail): "The GitHub Releases check failed: \(detail)"
        case let .artifactMismatch(detail): "The downloaded artifact does not match the published release: \(detail)"
        }
    }
}

public enum ReleaseMetadataVerifier {
    private static let repository = "https://github.com/markjoyeuxcom/parley"

    public static func verify(
        release: GitHubRelease,
        manifestData: Data,
        checksumData: Data
    ) throws -> ReleaseArtifactVerification {
        guard manifestData.count <= 1_024 * 1_024,
              checksumData.count <= 1_024 * 1_024 else {
            throw ReleaseLifecycleError.responseTooLarge
        }
        let manifest: ReleaseManifest
        do {
            manifest = try JSONDecoder().decode(ReleaseManifest.self, from: manifestData)
        } catch {
            throw ReleaseLifecycleError.invalidMetadata("release manifest is not valid JSON")
        }
        guard manifest.schemaVersion == 1,
              manifest.application.name == "Parley",
              manifest.application.bundleIdentifier == ParleyRuntime.productionBundleIdentifier,
              manifest.application.version == release.version,
              manifest.platform.operatingSystem == "macOS",
              manifest.platform.architecture == "arm64",
              manifest.source.repository == repository,
              manifest.source.commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw ReleaseLifecycleError.invalidMetadata("manifest identity does not match Parley and this release")
        }
        let releaseDMGs = release.assets.filter { $0.name.hasSuffix("-mac-arm64.dmg") }
        let manifests = release.assets.filter { $0.name.hasSuffix("-mac-arm64.release.json") }
        let checksumAssets = release.assets.filter { $0.name.hasSuffix("-mac-arm64.SHA256SUMS") }
        guard releaseDMGs.count == 1, manifests.count == 1, checksumAssets.count == 1,
              let dmg = releaseDMGs.first,
              let manifestArtifact = manifest.artifacts.first(where: { $0.file == dmg.name }),
              manifestArtifact.bytes == dmg.size,
              manifestArtifact.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw ReleaseLifecycleError.incompleteRelease
        }
        let checksums = try parseChecksums(checksumData)
        guard checksums[dmg.name] == manifestArtifact.sha256 else {
            throw ReleaseLifecycleError.invalidMetadata("manifest and SHA256SUMS disagree about the DMG")
        }
        return ReleaseArtifactVerification(
            version: release.version,
            dmgName: dmg.name,
            byteCount: dmg.size,
            sha256: manifestArtifact.sha256,
            downloadURL: dmg.browserDownloadURL,
            releasePageURL: release.htmlURL,
            signing: manifest.trust.signing,
            notarized: manifest.trust.notarized
        )
    }

    private static func parseChecksums(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReleaseLifecycleError.invalidMetadata("SHA256SUMS is not UTF-8")
        }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else {
                throw ReleaseLifecycleError.invalidMetadata("SHA256SUMS contains an invalid row")
            }
            let digest = String(fields[0])
            let name = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  !name.isEmpty,
                  URL(fileURLWithPath: name).lastPathComponent == name,
                  values[name] == nil else {
                throw ReleaseLifecycleError.invalidMetadata("SHA256SUMS contains an unsafe row")
            }
            values[name] = digest
        }
        return values
    }
}

public enum ReleaseArtifactVerifier {
    public static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(file: URL, expected: ReleaseArtifactVerification) throws {
        guard file.isFileURL,
              file.lastPathComponent == expected.dmgName,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == expected.byteCount else {
            throw ReleaseLifecycleError.artifactMismatch("filename or byte count differs")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.sha256 else {
            throw ReleaseLifecycleError.artifactMismatch("SHA-256 differs")
        }
    }
}

public final class GitHubReleaseService: @unchecked Sendable {
    public static let catalogURL = URL(string: "https://api.github.com/repos/markjoyeuxcom/parley/releases?per_page=20")!
    public static let releasesPageURL = URL(string: "https://github.com/markjoyeuxcom/parley/releases")!
    private let session: URLSession
    private let fileManager: FileManager

    public init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    public func check(channel: UpdateChannel, currentVersion: String) async throws -> ReleaseCheckResult {
        let catalogData = try await fetch(Self.catalogURL, maximumBytes: GitHubReleaseCatalog.maximumResponseBytes)
        let catalog = try GitHubReleaseCatalog.decode(catalogData)
        guard let release = catalog.selected(for: channel) else {
            throw ReleaseLifecycleError.noRelease(channel)
        }
        guard let manifest = release.assets.first(where: { $0.name.hasSuffix("-mac-arm64.release.json") }),
              let checksums = release.assets.first(where: { $0.name.hasSuffix("-mac-arm64.SHA256SUMS") }) else {
            throw ReleaseLifecycleError.incompleteRelease
        }
        let manifestData = try await fetch(manifest.browserDownloadURL, maximumBytes: 1_024 * 1_024)
        let checksumData = try await fetch(checksums.browserDownloadURL, maximumBytes: 1_024 * 1_024)
        let verification = try ReleaseMetadataVerifier.verify(
            release: release,
            manifestData: manifestData,
            checksumData: checksumData
        )
        return ReleaseCheckResult(
            channel: channel,
            currentVersion: currentVersion,
            release: release,
            updateState: release.updateState(currentVersion: currentVersion),
            verification: verification
        )
    }

    public func downloadVerifiedDMG(
        _ verification: ReleaseArtifactVerification,
        to destination: URL
    ) async throws {
        guard destination.isFileURL,
              destination.pathExtension.caseInsensitiveCompare("dmg") == .orderedSame,
              destination.lastPathComponent == verification.dmgName,
              fileManager.fileExists(atPath: destination.deletingLastPathComponent().path),
              GitHubReleaseCatalog.validDownloadURL(verification.downloadURL) else {
            throw ReleaseLifecycleError.invalidDestination
        }
        var request = URLRequest(url: verification.downloadURL)
        request.setValue("Parley update checker", forHTTPHeaderField: "User-Agent")
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(for: request)
        } catch {
            throw ReleaseLifecycleError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ReleaseLifecycleError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let namedTemporary = fileManager.temporaryDirectory
            .appendingPathComponent(verification.dmgName)
        if fileManager.fileExists(atPath: namedTemporary.path) {
            try fileManager.removeItem(at: namedTemporary)
        }
        try fileManager.moveItem(at: temporary, to: namedTemporary)
        defer { try? fileManager.removeItem(at: namedTemporary) }
        try ReleaseArtifactVerifier.verify(file: namedTemporary, expected: verification)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: namedTemporary)
        } else {
            try fileManager.moveItem(at: namedTemporary, to: destination)
        }
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Parley update checker", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReleaseLifecycleError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ReleaseLifecycleError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= maximumBytes else { throw ReleaseLifecycleError.responseTooLarge }
        return data
    }
}

private struct ParleySemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ value: String) {
        let coreAndMetadata = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let coreAndPre = coreAndMetadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = coreAndPre[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              let major = Int(numbers[0]),
              let minor = Int(numbers[1]),
              let patch = Int(numbers[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        let prerelease = coreAndPre.count == 2
            ? coreAndPre[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (left: ParleySemanticVersion, right: ParleySemanticVersion) -> Bool {
        if left.major != right.major { return left.major < right.major }
        if left.minor != right.minor { return left.minor < right.minor }
        if left.patch != right.patch { return left.patch < right.patch }
        if left.prerelease.isEmpty != right.prerelease.isEmpty { return !left.prerelease.isEmpty }
        for index in 0..<max(left.prerelease.count, right.prerelease.count) {
            if index >= left.prerelease.count { return true }
            if index >= right.prerelease.count { return false }
            let l = left.prerelease[index]
            let r = right.prerelease[index]
            if l == r { continue }
            if let ln = Int(l), let rn = Int(r) { return ln < rn }
            if Int(l) != nil { return true }
            if Int(r) != nil { return false }
            return l < r
        }
        return false
    }
}

private struct ReleaseManifest: Decodable {
    struct Application: Decodable {
        let name: String
        let bundleIdentifier: String
        let version: String
        let build: String
    }
    struct Platform: Decodable {
        let operatingSystem: String
        let architecture: String
        let minimumVersion: String
    }
    struct Trust: Decodable {
        let signing: String
        let notarized: Bool
        let gatekeeperReady: Bool
    }
    struct Source: Decodable {
        let repository: String
        let commit: String
    }
    struct Artifact: Decodable {
        let file: String
        let bytes: Int
        let sha256: String
    }

    let schemaVersion: Int
    let application: Application
    let platform: Platform
    let trust: Trust
    let source: Source
    let artifacts: [Artifact]
}
