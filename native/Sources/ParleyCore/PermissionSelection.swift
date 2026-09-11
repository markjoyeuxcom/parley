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

public struct PermissionProfileSelection: Codable, Equatable, Sendable {
    public let profileID: String
    public let approvedRoots: [String]
    public let lifetime: PermissionProfileLifetime

    public init(profileID: String, approvedRoots: [String], lifetime: PermissionProfileLifetime) {
        self.profileID = profileID
        self.approvedRoots = approvedRoots
        self.lifetime = lifetime
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