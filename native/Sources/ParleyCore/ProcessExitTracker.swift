import Foundation

/// Turns repeated observations of Ghostty's exit record into one report per
/// pane launch generation. An unreadable record is unknown and never an exit;
/// a restart is a new generation with its own report; a pane missing from a
/// pass is forgotten, so the record is bounded by the live panes.
public struct ProcessExitTracker: Sendable {
    public struct Observation: Equatable, Sendable {
        public let paneID: String
        public let generation: Int
        public let exited: Bool?
        public init(paneID: String, generation: Int, exited: Bool?) {
            self.paneID = paneID
            self.generation = generation
            self.exited = exited
        }
    }

    public struct Exit: Equatable, Sendable {
        public let paneID: String
        public let generation: Int
        public init(paneID: String, generation: Int) {
            self.paneID = paneID
            self.generation = generation
        }
    }

    private var reported: [String: Int] = [:]

    public init() {}

    /// The exits not reported before, in the order observed.
    public mutating func exits(_ observations: [Observation]) -> [Exit] {
        reported = reported.filter { entry in observations.contains { $0.paneID == entry.key } }
        var result: [Exit] = []
        for observation in observations where observation.exited == true && reported[observation.paneID] != observation.generation {
            reported[observation.paneID] = observation.generation
            result.append(Exit(paneID: observation.paneID, generation: observation.generation))
        }
        return result
    }
}
