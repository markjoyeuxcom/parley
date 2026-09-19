import Foundation

public enum ApplicationSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case terminal
    case appearance
    case notifications

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general:
            "General"
        case .terminal:
            "Terminal"
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
        case .terminal:
            "terminal"
        case .appearance:
            "textformat"
        case .notifications:
            "bell"
        }
    }
}
