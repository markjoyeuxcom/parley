import Foundation

/// Whether a link clicked in a terminal pane may be opened.
///
/// Pane output is written by a vendor CLI, not by the person, and an OSC 8
/// hyperlink can display one thing while pointing somewhere else. A click is
/// therefore treated as untrusted input: only an ordinary web URL opens, never
/// a scheme that would launch something local (`file:`, `javascript:`, or a
/// custom application scheme registered on this Mac).
public enum TerminalLinkPolicy {
    /// Web schemes only. Anything able to start a local process or read a local
    /// path is refused, because terminal text is not a person's intent.
    public static let allowedSchemes: Set<String> = ["http", "https"]
    public static let maximumLength = 4096

    /// The URL to open, or nil when the click must be ignored.
    public static func openableURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, raw.utf8.count <= maximumLength else { return nil }
        // A control character can hide the real destination in a rendered link.
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        guard allowedSchemes.contains(scheme) else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
