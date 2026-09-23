import GhosttyKit
import GhosttyTerminal

/// Ghostty's own record that a surface's child process has exited
/// (`ghostty_surface_process_exited`), the fact behind its "Process exited"
/// message. Parley forces wait-after-command, so Ghostty never closes such a
/// surface by itself, and the wrapper neither forwards
/// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` nor exposes this call (checked against
/// libghostty-spm 1.6.20260909 and 1.6.20260922). The raw surface is the
/// wrapper's one private stored `surface` field, read by reflection; the
/// wrapper sets it to nil when it frees the surface. `ProcessExitChecks`
/// runs this against real surfaces, so a wrapper change that moves the field
/// fails the suite rather than silently reporting nothing.
public enum GhosttyProcessExit {
    /// True once the child has exited, false while it runs, nil when the
    /// record cannot be read. Nil is unknown, never an exit.
    @MainActor
    public static func hasExited(_ surface: TerminalSurface) -> Bool? {
        guard let raw = rawSurface(surface) else { return nil }
        return ghostty_surface_process_exited(raw)
    }

    private static func rawSurface(_ surface: TerminalSurface) -> ghostty_surface_t? {
        for child in Mirror(reflecting: surface).children where child.label == "surface" {
            return child.value as? ghostty_surface_t
        }
        return nil
    }
}
