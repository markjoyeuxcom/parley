import Foundation

/// Routing roles are owner-controlled metadata independent of a pane's display
/// name: lowercase bounded slugs, unique per workspace; vendor names and
/// `lead` are reserved.
public enum PaneRoleRules {
    public static let maximumLength = 32
    private static let reserved = Set(
        PaneKind.allCases.flatMap { [$0.rawValue.lowercased(), $0.label.lowercased()] }
            + ["lead"]
    )

    public static func validationError(_ role: String) -> String? {
        guard role == role.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...maximumLength).contains(role.count),
              role == role.lowercased(),
              let first = role.utf8.first,
              (ascii("a")...ascii("z")).contains(first),
              role.utf8.allSatisfy({ byte in
                  (ascii("a")...ascii("z")).contains(byte)
                      || (ascii("0")...ascii("9")).contains(byte)
                      || byte == ascii("-")
              }),
              role.utf8.last != ascii("-") else {
            return "roles must be 1–\(maximumLength) lowercase letters, numbers or hyphens, beginning with a letter"
        }
        if reserved.contains(role) {
            return "the role \(role) is reserved for built-in routing"
        }
        return nil
    }

    private static func ascii(_ character: Character) -> UInt8 { character.asciiValue! }
}
