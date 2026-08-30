import Foundation

public enum TerminalFontPreferenceError: LocalizedError, Equatable, Sendable {
    case invalidFamily
    case invalidSize

    public var errorDescription: String? {
        switch self {
        case .invalidFamily:
            "Choose an installed font family with a valid name."
        case .invalidSize:
            "Choose a terminal font size from 8 to 72 points."
        }
    }
}

public struct TerminalFontPreference: Codable, Equatable, Sendable {
    public static let minimumSize = 8.0
    public static let maximumSize = 72.0

    public let family: String?
    public let size: Double?

    public static let ghosttyDefault = TerminalFontPreference(validatedFamily: nil, size: nil)

    private init(validatedFamily: String?, size: Double?) {
        family = validatedFamily
        self.size = size
    }

    public init(family: String? = nil, size: Double? = nil) throws {
        let trimmedFamily = family?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedFamily, !trimmedFamily.isEmpty {
            guard trimmedFamily.count <= 128,
                  trimmedFamily.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw TerminalFontPreferenceError.invalidFamily
            }
            self.family = trimmedFamily
        } else {
            self.family = nil
        }

        if let size {
            guard size.isFinite,
                  Self.minimumSize ... Self.maximumSize ~= size else {
                throw TerminalFontPreferenceError.invalidSize
            }
        }
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case family
        case size
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            family: try values.decodeIfPresent(String.self, forKey: .family),
            size: try values.decodeIfPresent(Double.self, forKey: .size)
        )
    }
}
