import Foundation
import ParleyCore

private func layoutExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "LayoutLeaf", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Review of 22 September 2026, a29ccc78: a team container member was added
/// to the layout by the one-second refresh while Docker preparation was
/// awaited, then inserted again beside the lead. The tree became
/// [lead, member, member]; two hosts shared one retained Ghostty view (the
/// v0.1.35 blank-pane class) and the duplicate survived relaunch. Each pane
/// id appears in a layout at most once.
func checkLayoutLeavesAppearOnce() throws {
    // The refresh has already reconciled the member into the tree.
    let reconciled = try NativeLayoutNode.reconciled(.leaf("lead"), with: ["lead", "member"]).unwrap()
    let inserted = try reconciled.inserting("member", after: "lead", direction: .vertical).unwrap()
    try layoutExpect(inserted.leaves == ["lead", "member"], "inserting a leaf already in the tree duplicated it: \(inserted.leaves)")
    try layoutExpect(inserted == .split(direction: .vertical, first: .leaf("lead"), second: .leaf("member")),
                     "the member was not placed beside the lead as requested: \(inserted)")
    // A tree persisted with a duplicate is repaired by reconciliation.
    let stored = NativeLayoutNode.split(direction: .horizontal,
        first: .split(direction: .horizontal, first: .leaf("lead"), second: .leaf("member")), second: .leaf("member"))
    let repaired = try NativeLayoutNode.reconciled(stored, with: ["lead", "member"]).unwrap()
    try layoutExpect(repaired.leaves == ["lead", "member"], "a stored duplicate leaf survived reconciliation: \(repaired.leaves)")
    // A leaf inserted after itself is refused rather than duplicated.
    try layoutExpect(NativeLayoutNode.leaf("lead").inserting("lead", after: "lead", direction: .horizontal) == nil,
                     "a leaf was inserted after itself")
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw NSError(domain: "LayoutLeaf", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected nil layout"]) }
        return self
    }
}

@MainActor let layoutLeafChecks: [(String, () throws -> Void)] = [
    ("layout leaves appear once", checkLayoutLeavesAppearOnce),
]
