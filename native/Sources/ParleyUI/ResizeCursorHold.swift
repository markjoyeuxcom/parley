/// Whether a split divider holds the resize cursor it pushed. AppKit's cursor
/// stack pops whatever is on top, so every push needs exactly one pop: when
/// the pointer leaves (zoomed or not), and when the divider goes away under
/// the pointer, which sends no hover-end. A class, held in `@State`, so a
/// hover changes no observed state and does not redraw the terminals beside
/// the divider.
public final class ResizeCursorHold {
    public enum Change: Equatable { case push, pop, none }

    public private(set) var held = false

    public init() {}

    /// `allowed` is false while a pane is zoomed: no new push then, but a
    /// cursor already pushed is still popped.
    public func hover(_ hovering: Bool, allowed: Bool) -> Change {
        if hovering {
            guard allowed, !held else { return .none }
            held = true
            return .push
        }
        return release()
    }

    public func release() -> Change {
        guard held else { return .none }
        held = false
        return .pop
    }
}
