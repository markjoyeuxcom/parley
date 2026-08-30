import Foundation

/// Response shape used only to retire the standalone core left by builds that
/// predate app-resident coordination. Remove this bridge after that upgrade
/// window closes; current Parley instances never expose its shutdown route.
public struct LegacyCoreShutdownReadiness: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let activeConsultations: Int
    public let activeDelegations: Int
    public let activeDispatches: Int

    public init(
        accepted: Bool,
        activeConsultations: Int,
        activeDelegations: Int,
        activeDispatches: Int
    ) {
        self.accepted = accepted
        self.activeConsultations = activeConsultations
        self.activeDelegations = activeDelegations
        self.activeDispatches = activeDispatches
    }

    public var activeWorkCount: Int {
        activeConsultations + activeDelegations + activeDispatches
    }
}
