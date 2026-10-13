import Foundation

/// A configuration store Parley reads at launch. When one cannot be read the
/// app runs on defaults for that store, says so in Settings and Status Center,
/// keeps the unreadable bytes beside the store for repair, and never writes
/// the defaults back over them as if they were a choice.
public enum ConfigurationStore: String, CaseIterable, Identifiable, Sendable {
    case terminalFont
    case terminalAppearanceImport
    case terminalSurfaceOptions
    case workspaceRegistry
    case savedLayouts
    case handoffRecipes
    case permissionProfiles
    case favouriteFolders

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .terminalFont: "Terminal font"
        case .terminalAppearanceImport: "Imported Ghostty appearance"
        case .terminalSurfaceOptions: "Ghostty surface options"
        case .workspaceRegistry: "Workspace split layouts"
        case .savedLayouts: "Saved layouts"
        case .handoffRecipes: "Recipes"
        case .permissionProfiles: "Permission profiles"
        case .favouriteFolders: "Favourite folders and workspace order"
        }
    }

    /// Where the store lives: a file in the runtime's Application Support
    /// directory, or a key in the runtime's preference domain.
    public var location: ConfigurationStoreLocation {
        switch self {
        case .terminalFont: .preference("parley.terminalFontPreference")
        case .terminalAppearanceImport: .preference("parley.terminalAppearanceImport")
        case .terminalSurfaceOptions: .preference("parley.terminalSurfacePreference")
        case .workspaceRegistry: .file("workspace-registry.json")
        case .savedLayouts: .file("workspace-layouts.json")
        case .handoffRecipes: .file("handoff-recipes.json")
        case .permissionProfiles: .file("permission-profiles.json")
        case .favouriteFolders: .preference("parley.workspaceContinuity")
        }
    }

    /// What Parley does without the store, shown beside the failure.
    public var fallback: String {
        switch self {
        case .terminalFont: "Parley's default font is in use."
        case .terminalAppearanceImport: "No imported appearance is in use; import it again from Settings > Appearance."
        case .terminalSurfaceOptions: "Ghostty's own defaults are in use."
        case .workspaceRegistry: "Each workspace shows one pane until you split it again; saved splits are not changed on disk."
        case .savedLayouts: "No saved layout is offered until the file is repaired or removed."
        case .handoffRecipes: "The built-in recipe texts are in use."
        case .permissionProfiles: "Only the built-in profiles are offered, and agent launches that need a custom profile are refused."
        case .favouriteFolders: "Favourites and the remembered workspace order start empty."
        }
    }
}

public enum ConfigurationStoreLocation: Equatable, Sendable {
    case file(String)
    case preference(String)

    public var description: String {
        switch self {
        case let .file(name): name
        case let .preference(key): "preference \(key)"
        }
    }
}

/// One store that could not be read at launch.
public struct ConfigurationLoadIssue: Identifiable, Equatable, Sendable {
    public let store: ConfigurationStore
    /// The store's own reason, as its error described it.
    public let reason: String
    /// Where the unreadable bytes were kept: a sibling file or a preference
    /// key, nil when nothing could be kept.
    public let preservedCopy: String?

    public init(store: ConfigurationStore, reason: String, preservedCopy: String?) {
        self.store = store
        self.reason = reason
        self.preservedCopy = preservedCopy
    }

    public var id: String { store.rawValue }

    /// One sentence for Settings and Status Center.
    public var summary: String {
        var text = "\(store.title) could not be read (\(store.location.description)): \(reason) \(store.fallback)"
        if let preservedCopy {
            text += " The unreadable copy was kept as \(preservedCopy)."
        } else {
            text += " Nothing was changed on disk."
        }
        return text
    }
}

/// Keeps the bytes of a store Parley could not read, so a person can repair
/// or inspect them, and leaves the original where it was: the app runs on
/// defaults and does not write them over the file.
public enum ConfigurationPreservation {
    /// Copies `file` to a sibling named `<name>.unreadable-<stamp>` and
    /// returns that URL. The copy is created exclusively, so a second launch
    /// in the same second makes a second copy rather than overwriting.
    public static func preserve(file: URL, fileManager: FileManager = .default, now: Date = Date()) throws -> URL {
        var copy = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).unreadable-\(stamp(now))")
        var attempt = 0
        while fileManager.fileExists(atPath: copy.path) {
            attempt += 1
            copy = file.deletingLastPathComponent()
                .appendingPathComponent("\(file.lastPathComponent).unreadable-\(stamp(now))-\(attempt)")
        }
        try fileManager.copyItem(at: file, to: copy)
        return copy
    }

    /// The key an unreadable preference value is moved to.
    public static func preservedKey(for key: String) -> String { "\(key).unreadable" }

    /// Moves the value under `key` to its preserved key and clears `key`, so
    /// the next save does not overwrite what the person had.
    public static func preserve(preferenceKey key: String, in defaults: UserDefaults) -> String? {
        guard let value = defaults.object(forKey: key) else { return nil }
        let preserved = preservedKey(for: key)
        defaults.set(value, forKey: preserved)
        defaults.removeObject(forKey: key)
        return preserved
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
