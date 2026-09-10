import Foundation

/// Native settings for this app session only. No file or preference domain
/// can restore execution authority. A new app session always starts off.
public struct CommandRunAuthorizationSession: Equatable, Sendable {
    public var automaticApproval = false
    public var closeCleanPanes = false
    public init() {}
}
