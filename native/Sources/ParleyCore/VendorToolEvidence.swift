import Foundation

/// What Parley can prove about effective browser/tool access in one live pane.
/// Permission intent, CLI help text and successful-looking terminal prose never
/// upgrade Unknown to Verified.
public enum VendorToolAccessState: String, Codable, Equatable, Sendable {
    case verified
    case unknown
    case unavailable

    public var label: String {
        switch self {
        case .verified: "Verified"
        case .unknown: "Unknown"
        case .unavailable: "Unavailable"
        }
    }
}

public struct PaneToolCapabilitySummary: Equatable, Sendable {
    public let paneID: String
    public let vendor: PaneKind
    public let toolAccess: VendorToolAccessState
    public let detail: String
    public let permissionProfileName: String?
    public let networkRule: PermissionRule?
    public let permissionEnforcement: PermissionEnforcementLevel?
    public let canCaptureEvidence: Bool

    public init(
        paneID: String,
        vendor: PaneKind,
        toolAccess: VendorToolAccessState,
        detail: String,
        permissionProfileName: String?,
        networkRule: PermissionRule?,
        permissionEnforcement: PermissionEnforcementLevel?,
        canCaptureEvidence: Bool
    ) {
        self.paneID = paneID
        self.vendor = vendor
        self.toolAccess = toolAccess
        self.detail = detail
        self.permissionProfileName = permissionProfileName
        self.networkRule = networkRule
        self.permissionEnforcement = permissionEnforcement
        self.canCaptureEvidence = canCaptureEvidence
    }

    public var networkLabel: String {
        let rule = switch networkRule {
        case .allow: "Allowed by profile intent"
        case .requireApproval: "Approval required by profile intent"
        case .deny: "Denied by profile intent"
        case nil: "Not recorded"
        }
        guard let permissionProfileName else { return rule }
        let enforcement = permissionEnforcement?.label ?? "not recorded"
        return "\(rule) · profile \(permissionProfileName) · overall launch \(enforcement)"
    }
}

/// Pure, quota-free projection over facts Parley already owns. No vendor
/// configuration, credential store, terminal transcript or website is read.
public enum PaneToolCapabilityProjection {
    public static func summary(
        for pane: WorkbenchPane,
        profiles: [PermissionProfileDefinition]
    ) -> PaneToolCapabilitySummary {
        let selectedProfile = pane.permissionSelection.flatMap { selection in
            profiles.first(where: { $0.id == selection.profileID })
        }
        let profileName = selectedProfile?.name ?? pane.permissionSelection?.profileID
        let networkRule = selectedProfile?.rule(for: .networkAccess)

        guard pane.kind.isAgent else {
            return PaneToolCapabilitySummary(
                paneID: pane.id,
                vendor: pane.kind,
                toolAccess: .unavailable,
                detail: "Shell panes do not have a vendor-owned agent tool runtime.",
                permissionProfileName: profileName,
                networkRule: networkRule,
                permissionEnforcement: pane.permissionEnforcement,
                canCaptureEvidence: false
            )
        }
        guard pane.isStarted, !pane.isDead else {
            return PaneToolCapabilitySummary(
                paneID: pane.id,
                vendor: pane.kind,
                toolAccess: .unavailable,
                detail: "This vendor pane is not running. Start it before attributing new browser or tool evidence to it.",
                permissionProfileName: profileName,
                networkRule: networkRule,
                permissionEnforcement: pane.permissionEnforcement,
                canCaptureEvidence: false
            )
        }

        return PaneToolCapabilitySummary(
            paneID: pane.id,
            vendor: pane.kind,
            toolAccess: .unknown,
            detail: "Parley has no credential-free, quota-free inspection that proves effective browser or tool access in this pane. Permission intent and terminal output are not evidence of availability.",
            permissionProfileName: profileName,
            networkRule: networkRule,
            permissionEnforcement: pane.permissionEnforcement,
            canCaptureEvidence: true
        )
    }
}

public enum VendorToolEvidenceKind: String, CaseIterable, Codable, Equatable, Sendable {
    case browserURL
    case browserSelection
    case browserScreenshot
    case savedArtifact

    public var label: String {
        switch self {
        case .browserURL: "Browser URL"
        case .browserSelection: "Browser selected text"
        case .browserScreenshot: "Browser screenshot"
        case .savedArtifact: "Saved tool artifact"
        }
    }
}

public enum VendorToolEvidenceCaptureBasis: String, Codable, Equatable, Sendable {
    case personProvidedURL
    case personProvidedSelection
    case parleyInspectedLocalArtifact

    public var detail: String {
        switch self {
        case .personProvidedURL:
            "The person supplied this URL; Parley did not fetch or verify its page."
        case .personProvidedSelection:
            "The person supplied this selected text and URL; Parley did not compare it with the page."
        case .parleyInspectedLocalArtifact:
            "The person selected this local file; Parley measured and hashed its bytes without opening a browser session."
        }
    }
}

/// A provenance stamp embedded in a context-pack source. Pane attribution is a
/// person's explicit assertion; local artifact size and digest are independently
/// measured by Parley. Browser access itself remains Unknown until an adapter can
/// establish it safely for that exact pane.
public struct VendorToolEvidenceProvenance: Codable, Equatable, Sendable {
    public let kind: VendorToolEvidenceKind
    public let vendor: PaneKind
    public let paneID: String
    public let paneName: String
    public let sourceURL: String?
    public let artifactPath: String?
    public let artifactByteCount: Int?
    public let sha256: String?
    public let capturedAt: Date
    public let captureBasis: VendorToolEvidenceCaptureBasis
    public let toolAccess: VendorToolAccessState
    public let toolAccessDetail: String

    public init(
        kind: VendorToolEvidenceKind,
        vendor: PaneKind,
        paneID: String,
        paneName: String,
        sourceURL: String?,
        artifactPath: String?,
        artifactByteCount: Int?,
        sha256: String?,
        capturedAt: Date,
        captureBasis: VendorToolEvidenceCaptureBasis,
        toolAccess: VendorToolAccessState,
        toolAccessDetail: String
    ) {
        self.kind = kind
        self.vendor = vendor
        self.paneID = paneID
        self.paneName = paneName
        self.sourceURL = sourceURL
        self.artifactPath = artifactPath
        self.artifactByteCount = artifactByteCount
        self.sha256 = sha256
        self.capturedAt = capturedAt
        self.captureBasis = captureBasis
        self.toolAccess = toolAccess
        self.toolAccessDetail = toolAccessDetail
    }
}
