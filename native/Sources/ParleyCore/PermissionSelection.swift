import Foundation

/// What a person chose about a pane's permissions, as a value.
///
/// A selection names a profile, how long the choice lasts and how strongly it
/// is enforced. Resolving that into effective roots means touching the
/// filesystem — canonicalising paths, checking file identity and ownership —
/// and that stays in `PermissionProfiles.swift` with the platform it needs.
///
/// Separating them matters because a selection is recorded: it travels in
/// handoffs, team grants and container configurations, all of which should be
/// readable without the resolver behind them.

public enum PermissionProfileLifetime: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case session
    case remembered
}

/// Who answers a vendor's permission prompt for this pane. `person` is the
/// vendor's ordinary prompt. `vendorReviewer` selects the vendor's own
/// automatic reviewer where one exists: Claude's auto mode classifier, Codex's
/// auto review, Copilot's assisted approval. Each keeps the vendor's sandbox
/// and its deny and ask rules and can still refuse; none is a bypass, and
/// Parley never passes a skip-all flag on the host. Agy has no reviewer, so
/// the choice changes nothing for it and the review says so.
public enum PermissionApprovalHandling: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case person
    case vendorReviewer

    public var label: String {
        switch self {
        case .person: "You approve"
        case .vendorReviewer: "Vendor's automatic reviewer"
        }
    }
}

public struct PermissionProfileSelection: Codable, Equatable, Sendable {
    public let profileID: String
    public let approvedRoots: [String]
    public let lifetime: PermissionProfileLifetime
    /// Absent from every record written before the choice existed; those
    /// decode as the person answering, which is what they were.
    public let approvals: PermissionApprovalHandling

    public init(profileID: String, approvedRoots: [String], lifetime: PermissionProfileLifetime,
                approvals: PermissionApprovalHandling = .person) {
        self.profileID = profileID
        self.approvedRoots = approvedRoots
        self.lifetime = lifetime
        self.approvals = approvals
    }

    private enum CodingKeys: String, CodingKey { case profileID, approvedRoots, lifetime, approvals }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(String.self, forKey: .profileID)
        approvedRoots = try container.decode([String].self, forKey: .approvedRoots)
        lifetime = try container.decode(PermissionProfileLifetime.self, forKey: .lifetime)
        approvals = try container.decodeIfPresent(PermissionApprovalHandling.self, forKey: .approvals) ?? .person
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(approvedRoots, forKey: .approvedRoots)
        try container.encode(lifetime, forKey: .lifetime)
        try container.encode(approvals, forKey: .approvals)
    }

    /// Base64 keeps paths and JSON punctuation out of the durable metadata
    /// envelope while retaining a portable value.
    public var metadataValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return data.base64EncodedString()
    }

    public init?(metadataValue: String) {
        guard !metadataValue.isEmpty,
              let data = Data(base64Encoded: metadataValue),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

/// A profile expresses more than any vendor CLI currently enforces. Parley
/// therefore distinguishes exact enforcement from a safe partial translation
/// and from launch guidance that the vendor must still confirm itself.
public enum PermissionEnforcementLevel: String, Codable, Equatable, Sendable {
    case enforced
    case partiallyEnforced
    case guidanceOnly

    public var label: String {
        switch self {
        case .enforced: "Enforced"
        case .partiallyEnforced: "Partially enforced"
        case .guidanceOnly: "Guidance only"
        }
    }
}