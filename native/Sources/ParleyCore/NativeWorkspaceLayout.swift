import Foundation

/// Natural ordering for ephemeral pane ids: `%2` precedes `%10`. This is
/// presentation ordering only; durable state never uses a live id as identity.
public enum WorkbenchIdentifierOrder {
    public static func sorted<S: Sequence>(_ identifiers: S) -> [String]
    where S.Element == String {
        identifiers.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
}

/// The native split structure of one workspace's terminal leaves, combined by
/// split direction. Every leaf is one retained Ghostty surface. Divider
/// positions stay with AppKit; the tree records only the structure that must
/// survive relaunches and reconciliation.
public indirect enum NativeLayoutNode: Codable, Equatable, Sendable {
    case leaf(String)
    case split(direction: SplitDirection, first: NativeLayoutNode, second: NativeLayoutNode)

    public var leaves: [String] {
        switch self {
        case let .leaf(paneID):
            [paneID]
        case let .split(_, first, second):
            first.leaves + second.leaves
        }
    }

    /// Splits the target leaf in the given direction, placing the new leaf
    /// after it. Returns nil when the target is absent or is the new leaf.
    /// A leaf already in the tree moves rather than repeats: the one-second
    /// refresh can reconcile a new pane in (a team container member, while
    /// Docker preparation is awaited) before its placement is recorded, and
    /// two leaves for one pane would mount one retained Ghostty view twice.
    public func inserting(_ newLeaf: String, after target: String, direction: SplitDirection) -> NativeLayoutNode? {
        guard newLeaf != target else { return nil }
        let base = leaves.contains(newLeaf) ? removing(newLeaf) : self
        return base?.placing(newLeaf, after: target, direction: direction)
    }

    private func placing(_ newLeaf: String, after target: String, direction: SplitDirection) -> NativeLayoutNode? {
        switch self {
        case let .leaf(paneID):
            guard paneID == target else { return nil }
            return .split(direction: direction, first: self, second: .leaf(newLeaf))
        case let .split(splitDirection, first, second):
            if let replaced = first.placing(newLeaf, after: target, direction: direction) {
                return .split(direction: splitDirection, first: replaced, second: second)
            }
            if let replaced = second.placing(newLeaf, after: target, direction: direction) {
                return .split(direction: splitDirection, first: first, second: replaced)
            }
            return nil
        }
    }

    /// The tree with each leaf kept at its first occurrence only; a later
    /// repeat collapses into its sibling. Nil only for an empty result.
    public func deduplicated() -> NativeLayoutNode? {
        var seen: Set<String> = []
        return keepingFirst(&seen)
    }

    private func keepingFirst(_ seen: inout Set<String>) -> NativeLayoutNode? {
        switch self {
        case let .leaf(paneID):
            return seen.insert(paneID).inserted ? self : nil
        case let .split(direction, first, second):
            let keptFirst = first.keepingFirst(&seen)
            let keptSecond = second.keepingFirst(&seen)
            switch (keptFirst, keptSecond) {
            case let (kept?, nil), let (nil, kept?): return kept
            case let (keptA?, keptB?): return .split(direction: direction, first: keptA, second: keptB)
            case (nil, nil): return nil
            }
        }
    }

    /// Removes a leaf, collapsing its parent split into the sibling. Returns
    /// nil when removing the only leaf.
    public func removing(_ target: String) -> NativeLayoutNode? {
        switch self {
        case let .leaf(paneID):
            return paneID == target ? nil : self
        case let .split(direction, first, second):
            let keptFirst = first.removing(target)
            let keptSecond = second.removing(target)
            switch (keptFirst, keptSecond) {
            case let (kept?, nil):
                return kept
            case let (nil, kept?):
                return kept
            case let (keptA?, keptB?):
                return .split(direction: direction, first: keptA, second: keptB)
            case (nil, nil):
                return nil
            }
        }
    }

    /// Aligns the tree with the live leaf set: repeated leaves keep their
    /// first place, vanished leaves collapse away and unknown leaves join at
    /// the root, side by side.
    public static func reconciled(_ tree: NativeLayoutNode?, with liveLeaves: [String]) -> NativeLayoutNode? {
        // A tree stored with a repeated leaf (before 23 September 2026) is
        // repaired here, so the next refresh persists the corrected tree.
        var result = tree?.deduplicated()
        if let existing = result {
            for leaf in existing.leaves where !liveLeaves.contains(leaf) {
                result = result?.removing(leaf)
            }
        }
        for leaf in liveLeaves where result?.leaves.contains(leaf) != true {
            if let current = result {
                result = .split(direction: .horizontal, first: current, second: .leaf(leaf))
            } else {
                result = .leaf(leaf)
            }
        }
        return result
    }

    /// Rebinds an ID-free saved split tree to freshly created pane ids in
    /// leaf order. A count mismatch is refused instead of silently inventing
    /// or dropping a pane.
    public static func mirroring(
        _ saved: SavedLayoutNode,
        paneIDs: [String]
    ) -> NativeLayoutNode? {
        guard saved.leaves.count == paneIDs.count else { return nil }
        var iterator = paneIDs.makeIterator()
        func convert(_ node: SavedLayoutNode) -> NativeLayoutNode? {
            switch node {
            case .leaf:
                guard let paneID = iterator.next() else { return nil }
                return .leaf(paneID)
            case let .split(direction, _, first, second):
                guard let convertedFirst = convert(first),
                      let convertedSecond = convert(second) else { return nil }
                return .split(
                    direction: direction,
                    first: convertedFirst,
                    second: convertedSecond
                )
            }
        }
        guard let converted = convert(saved), iterator.next() == nil else { return nil }
        return converted
    }

    /// A balanced arrangement of the given leaves with alternating split
    /// directions — the native meaning of Balance Panes.
    public static func tiled(_ leaves: [String], direction: SplitDirection = .horizontal) -> NativeLayoutNode? {
        guard let first = leaves.first else { return nil }
        guard leaves.count > 1 else { return .leaf(first) }
        let middle = (leaves.count + 1) / 2
        let next: SplitDirection = direction == .horizontal ? .vertical : .horizontal
        guard let left = tiled(Array(leaves[..<middle]), direction: next),
              let right = tiled(Array(leaves[middle...]), direction: next) else {
            return nil
        }
        return .split(direction: direction, first: left, second: right)
    }
}
