import Foundation

/// Copies only named, missing preferences from an earlier executable domain.
/// The packaged app uses a stable reverse-DNS bundle identifier, while the
/// SwiftPM development executable historically wrote under `parley-native`.
public enum UserDefaultsDomainMigration {
    public static func copyMissing(
        keys: [String],
        from legacyDomain: String,
        to defaults: UserDefaults
    ) {
        guard let legacyValues = defaults.persistentDomain(forName: legacyDomain) else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacyValues[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
}
