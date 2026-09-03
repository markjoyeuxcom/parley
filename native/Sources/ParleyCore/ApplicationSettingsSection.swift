import Foundation

public enum ApplicationSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case appearance
    case notifications

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general:
            "General"
        case .appearance:
            "Appearance"
        case .notifications:
            "Notifications"
        }
    }

    public var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .appearance:
            "textformat"
        case .notifications:
            "bell"
        }
    }
}
