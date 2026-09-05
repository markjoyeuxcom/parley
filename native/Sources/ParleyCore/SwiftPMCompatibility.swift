import Foundation

/// A runtime-local opt-in for SwiftPM inside the agent process boundary.
/// Selects Swift from the caller's current PATH, including mise shims.
public enum SwiftPMCompatibility {
    public static let explanation = "When enabled, SwiftPM build, test, run and package commands in new agent panes omit SwiftPM's additional subprocess sandbox. Project and dependency manifests and plugins run with the agent's existing permissions, including any permitted network access. This setting only automates the SwiftPM flag. Parley's outer boundary and vendor tool approvals remain active. Human Shell panes keep SwiftPM's normal defaults."

    public static func directory(in applicationDirectory: URL) -> URL {
        applicationDirectory.appendingPathComponent("agent-protocol/swiftpm-bin", isDirectory: true)
    }

    public static func install(in applicationDirectory: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = directory(in: applicationDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let command = directory.appendingPathComponent("swift")
        let otherCommands = Set(ParleyRuntime.controlDirectories().map {
            Self.directory(in: $0).appendingPathComponent("swift").path
        })
        let skipManagedCommands = otherCommands.sorted().map {
            "[ ! \"$parley_swift_candidate\" -ef \(shellLiteral($0)) ]"
        }.joined(separator: " && ")
        let script = #"""
        #!/bin/sh
        # Parley Native managed SwiftPM compatibility wrapper.
        set -eu
        parley_swift_remaining="${PATH-/usr/bin:/bin}"
        parley_swift_target=""
        while :; do
          case "$parley_swift_remaining" in
            *:*) parley_swift_directory="${parley_swift_remaining%%:*}"
                 parley_swift_remaining="${parley_swift_remaining#*:}"
                 parley_swift_more=1 ;;
            *)   parley_swift_directory="$parley_swift_remaining"
                 parley_swift_more=0 ;;
          esac
          [ -n "$parley_swift_directory" ] || parley_swift_directory=.
          parley_swift_candidate="$parley_swift_directory/swift"
          if [ -x "$parley_swift_candidate" ] && [ ! -d "$parley_swift_candidate" ] &&
             [ ! "$parley_swift_candidate" -ef "$0" ] && \#(skipManagedCommands); then
            parley_swift_target="$parley_swift_candidate"
            break
          fi
          [ "$parley_swift_more" = 1 ] || break
        done
        if [ -z "$parley_swift_target" ]; then
          echo "Parley could not find a Swift toolchain on PATH after excluding its compatibility wrapper." >&2
          exit 127
        fi

        if [ "${PARLEY_PANE:-}" = 1 ] && [ "${PARLEY_SWIFTPM_COMPATIBILITY:-}" = 1 ]; then
          case "${PARLEY_PANE_KIND:-}" in
            claude|codex|agy|copilot)
              case "${1:-}" in
                build|test|run|package)
                  parley_swift_subcommand="$1"
                  shift
                  exec "$parley_swift_target" "$parley_swift_subcommand" --disable-sandbox "$@"
                  ;;
              esac
              ;;
          esac
        fi
        exec "$parley_swift_target" "$@"
        """#
        try (script + "\n").write(to: command, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        return directory
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
