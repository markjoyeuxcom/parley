import Foundation

/// TOML basic strings for the `-c` values Parley gives Codex: the shared
/// protocol, the generated lifecycle hooks and the host permission table.
/// Codex parses every `-c` value as TOML and, when that fails, uses the whole
/// value as a literal string without saying so. JSON string escaping is not
/// TOML: a default `JSONEncoder` writes `/` as `\/`, which TOML rejects, and
/// until 22 September 2026 every Codex pane received the protocol as one
/// escaped line for that reason. This writes only escapes TOML 1.0 defines.
public enum TOMLString {
    public static func basic(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\u{8}": result += "\\b"
            case "\u{c}": result += "\\f"
            case _ where scalar.value < 0x20 || scalar.value == 0x7f:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
