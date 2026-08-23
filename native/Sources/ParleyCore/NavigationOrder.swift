import Foundation

public enum NavigationOrder {
    public static func adjacentID(
        currentID: String?,
        offset: Int,
        orderedIDs: [String]
    ) -> String? {
        guard !orderedIDs.isEmpty else { return nil }
        guard let currentID, let currentIndex = orderedIDs.firstIndex(of: currentID) else {
            return offset < 0 ? orderedIDs.last : orderedIDs.first
        }

        let count = orderedIDs.count
        let wrappedIndex = ((currentIndex + offset) % count + count) % count
        return orderedIDs[wrappedIndex]
    }
}
