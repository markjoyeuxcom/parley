import Foundation

/// Names and labels for panes that share a vendor.
///
/// A pane's default name is its vendor label, so a workspace that may use
/// one vendor only (a Claude-only workspace, for example) would otherwise
/// hold several panes called "Claude": indistinguishable in menus, and
/// refused as an ambiguous target by the broker, which matches the bare
/// vendor name against every pane of that vendor. Identity therefore comes
/// from the pane's name and routing role, and these helpers keep both
/// distinct without inventing anything the person did not choose.
public enum PaneNaming {
    public static let maximumNameLength = 80

    /// The name a creation review proposes for a new pane of `kind` among
    /// `panes`, the workspace it joins: nil while the vendor label is still
    /// free there, otherwise the label with the first free ordinal from 2
    /// ("Claude 2"). A pane the person renamed frees the label again.
    public static func defaultName(for kind: PaneKind, among panes: [WorkbenchPane]) -> String? {
        let taken = Set(panes.map { $0.displayName.lowercased() })
        guard taken.contains(kind.label.lowercased()) else { return nil }
        var ordinal = 2
        while taken.contains("\(kind.label) \(ordinal)".lowercased()) { ordinal += 1 }
        return "\(kind.label) \(ordinal)"
    }

    /// Why `name` cannot be a pane's custom name, or nil when it can. An
    /// empty name is allowed and means the vendor label.
    public static func nameValidationError(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximumNameLength else {
            return "pane names are at most \(maximumNameLength) characters"
        }
        guard !trimmed.contains("/") else {
            return "pane names cannot contain a slash; workspace/name is how a target in another workspace is written"
        }
        guard !trimmed.hasPrefix("@") else {
            return "pane names cannot begin with @, which names a routing role"
        }
        return nil
    }

    /// One label per pane id, distinct across all of `panes`. A name nobody
    /// else in the list shares is used as it is. A pane whose label collides
    /// with any other gains, in order and only as far as needed, its @role,
    /// its folder's last component and the start of its id, so two "Claude"
    /// panes read "Claude @reviewer" and "Claude @implementer", or "Claude ·
    /// api" and "Claude · web" when neither has a role. A decorated label
    /// can equal another pane's literal name ("Claude @reviewer"), so every
    /// label is compared with every other, and the full id ends any tie.
    public static func distinctLabels(for panes: [WorkbenchPane]) -> [String: String] {
        func withRole(_ pane: WorkbenchPane) -> String {
            pane.role.map { "\(pane.displayName) @\($0)" } ?? pane.displayName
        }
        func withFolder(_ pane: WorkbenchPane) -> String {
            "\(withRole(pane)) · \(WorkspaceFolderIdentity.displayName(for: pane.cwd))"
        }
        let stages: [(WorkbenchPane) -> String] = [
            { $0.displayName },
            withRole,
            withFolder,
            { "\(withFolder($0)) · \(shortID($0.id))" },
            { "\(withFolder($0)) · \($0.id)" },
        ]
        var stage = [String: Int](panes.map { ($0.id, 0) }, uniquingKeysWith: { first, _ in first })
        func label(_ pane: WorkbenchPane) -> String { stages[stage[pane.id] ?? 0](pane) }
        // Distinct without case, as the broker matches names, so "claude"
        // and "Claude" are told apart rather than left to look alike. Each
        // round moves every colliding pane one stage on; stages are finite.
        while true {
            var holders: [String: [String]] = [:]
            for pane in panes { holders[label(pane).lowercased(), default: []].append(pane.id) }
            let advancing = holders.values.filter { $0.count > 1 }.joined()
                .filter { (stage[$0] ?? 0) < stages.count - 1 }
            guard !advancing.isEmpty else { break }
            for id in Set(advancing) { stage[id, default: 0] += 1 }
        }
        return Dictionary(panes.map { ($0.id, label($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The start of a pane id without its "pane-" prefix: enough to tell two
    /// panes apart next to their names, never a substitute for the full id
    /// an agent must use.
    public static func shortID(_ id: String) -> String {
        let bare = id.hasPrefix("pane-") ? String(id.dropFirst(5)) : id
        return String(bare.prefix(8))
    }
}

public extension SavedWorkspaceLayout {
    /// The routing roles of the pair template, in pane order.
    static let pairTemplateRoles = ["implementer", "reviewer"]

    /// Two panes of one vendor side by side: an @implementer, marked as the
    /// workspace lead, and a @reviewer, both in `folder`. This is the shape
    /// a single-vendor workspace most often wants, built from the same
    /// saved-layout type as the person's own layouts, so restoring it
    /// follows every rule a saved layout does: shells start, agent panes
    /// stay stopped until the person reviews each Start, and nothing is
    /// written to the layout store unless the person saves it.
    static func pairTemplate(vendor: PaneKind, folder: String) -> SavedWorkspaceLayout {
        SavedWorkspaceLayout(
            name: "\(vendor.label) Pair",
            defaultFolder: folder,
            root: .split(
                direction: .horizontal,
                ratio: 0.5,
                first: .leaf(SavedLayoutLeaf(
                    kind: vendor, name: "Implementer", folder: folder, role: pairTemplateRoles[0], isWorkspaceLead: true
                )),
                second: .leaf(SavedLayoutLeaf(
                    kind: vendor, name: "Reviewer", folder: folder, role: pairTemplateRoles[1]
                ))
            )
        )
    }
}
