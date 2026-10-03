import Foundation

/// Which panes may take part in a person's Ask, and, when none can, the one
/// reason the toolbar shows instead of a disabled menu.
///
/// The Ask and Review menus used to disable themselves whenever there was no
/// target, so the one line that said why could not be opened, and that line
/// said another vendor was needed although two panes of the same vendor are a
/// valid route (Codex's review of 3 October 2026).
public enum AskAvailability {
    public static func isEligibleSource(_ pane: WorkbenchPane) -> Bool {
        pane.kind.isAgent && isRelayReady(pane)
    }

    public static func isEligibleTarget(_ pane: WorkbenchPane, source: WorkbenchPane) -> Bool {
        pane.kind.isAgent && pane.id != source.id && isRelayReady(pane)
    }

    public static func targets(source: WorkbenchPane?, panes: [WorkbenchPane]) -> [WorkbenchPane] {
        guard let source, isEligibleSource(source) else { return [] }
        return panes.filter { isEligibleTarget($0, source: source) }
    }

    /// Nil when the selected pane can ask at least one other pane.
    public static func unavailableReason(source: WorkbenchPane?, panes: [WorkbenchPane]) -> String? {
        guard let source, source.kind.isAgent else {
            return "Select an agent pane to ask from."
        }
        if !source.isStarted || source.isDead {
            return "The selected agent pane is not running. Start it from its pane menu."
        }
        if !source.hasCurrentProtocol {
            return "The selected pane needs Restart for Protocol before it can ask."
        }
        if !source.relayEnabled || !source.inputAvailable {
            return "The selected pane is not ready to relay yet."
        }
        let others = panes.filter { $0.kind.isAgent && $0.id != source.id }
        if others.isEmpty {
            return "Open a second agent pane to ask. Any vendor works, including the same one."
        }
        if !others.contains(where: { isEligibleTarget($0, source: source) }) {
            return "No other agent pane is ready: it must be running and on the current protocol."
        }
        return nil
    }

    private static func isRelayReady(_ pane: WorkbenchPane) -> Bool {
        pane.isStarted && !pane.isDead && pane.relayEnabled && pane.hasCurrentProtocol && pane.inputAvailable
    }
}
