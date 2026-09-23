import Foundation
import ParleyCore

private func tomlExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "CodexTOML", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// A strict reader for one TOML basic string, as TOML 1.0 defines it: the
/// escapes \b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX and nothing else, and no
/// raw control character other than tab. Codex parses every `-c` value as
/// TOML and, when that fails, uses the whole value as a literal string, so
/// an escape JSON allows but TOML does not (`\/`) silently turns the
/// protocol into one escaped line. `JSONDecoder` accepts `\/` and could not
/// catch that; this reader refuses it.
private func readTOMLBasicString(_ text: Substring) throws -> (value: String, rest: Substring) {
    func fail(_ reason: String) -> NSError {
        NSError(domain: "CodexTOML", code: 2, userInfo: [NSLocalizedDescriptionKey: "not a TOML basic string: \(reason)"])
    }
    var scalars = text.unicodeScalars[...]
    guard scalars.first == "\"" else { throw fail("no opening quote") }
    scalars = scalars.dropFirst()
    var value = String.UnicodeScalarView()
    while let scalar = scalars.first {
        scalars = scalars.dropFirst()
        switch scalar {
        case "\"":
            return (String(value), Substring(scalars))
        case "\\":
            guard let escape = scalars.first else { throw fail("a trailing backslash") }
            scalars = scalars.dropFirst()
            switch escape {
            case "b": value.append("\u{8}")
            case "t": value.append("\t")
            case "n": value.append("\n")
            case "f": value.append("\u{c}")
            case "r": value.append("\r")
            case "\"": value.append("\"")
            case "\\": value.append("\\")
            case "u", "U":
                let width = escape == "u" ? 4 : 8
                let digits = String(String.UnicodeScalarView(scalars.prefix(width)))
                guard digits.count == width, let code = UInt32(digits, radix: 16), let decoded = Unicode.Scalar(code) else {
                    throw fail("a malformed \\\(escape) escape")
                }
                value.append(decoded)
                scalars = scalars.dropFirst(width)
            default:
                throw fail("the escape \\\(escape), which TOML does not define")
            }
        default:
            if scalar != "\t", scalar.value < 0x20 || scalar.value == 0x7f {
                throw fail(String(format: "a raw control character U+%04X", scalar.value))
            }
            value.append(scalar)
        }
    }
    throw fail("no closing quote")
}

/// Every basic string in a TOML inline value, read strictly in order.
private func tomlBasicStrings(in value: String) throws -> [String] {
    var strings: [String] = []
    var rest = Substring(value)
    while let quote = rest.firstIndex(of: "\"") {
        let read = try readTOMLBasicString(rest[quote...])
        strings.append(read.value)
        rest = read.rest
    }
    return strings
}

/// Review of 22 September 2026, M1: every Codex pane received the shared
/// protocol as one escaped line because its `-c developer_instructions`
/// value was JSON with `\/`, which TOML rejects. Every Parley `-c` value
/// that carries a string must be valid TOML and read back exactly.
func checkCodexConfigurationValuesAreValidTOML() throws {
    let root = URL(fileURLWithPath: "/tmp/parley-toml-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let protocolDirectory = root.appendingPathComponent("agent-protocol", isDirectory: true)

    // The shared protocol text, which contains many `/` characters.
    try tomlExpect(AgentProtocol.text.contains("/"), "the protocol no longer contains a slash, so this check proves nothing")
    let codex = AgentProtocol.command(for: .codex, protocolDirectory: protocolDirectory)
    let argument = try tomlRequire(codex.first { $0.hasPrefix("developer_instructions=") }, "Codex received no developer instructions")
    let read = try readTOMLBasicString(argument.dropFirst("developer_instructions=".count))
    try tomlExpect(read.rest.isEmpty, "the developer instructions value continues after its string: \(read.rest.prefix(40))")
    try tomlExpect(read.value == AgentProtocol.text, "Codex would not read back the exact shared protocol")

    // The generated lifecycle hooks: each command is a TOML string.
    let hooks = VendorHookAdapter.launchArguments(for: .codex, protocolDirectory: protocolDirectory)
    let hookValues = stride(from: 1, to: hooks.count, by: 2).map { hooks[$0] }
    try tomlExpect(!hookValues.isEmpty && hooks.enumerated().allSatisfy { $0.offset % 2 == 1 || $0.element == "-c" },
                   "the Codex hook arguments are not -c pairs: \(hooks)")
    for value in hookValues {
        let strings = try tomlBasicStrings(in: value)
        let command: String = try tomlRequire(strings.first { $0.contains("signal") }, "a Codex hook carries no command string: \(value)")
        try tomlExpect(command.contains(protocolDirectory.path) || command.contains("/"), "a Codex hook command lost its path: \(command)")
    }

    // The host permission table: every path is a TOML string key or value.
    let application = root.appendingPathComponent("Parley Native/app", isDirectory: true)
    let project = root.appendingPathComponent("project/with \"quote\" and \\slash", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let profile = try PermissionProfileResolver.resolve(
        definition: PermissionProfileDefinition.builtIns.first { $0.rule(for: .projectWrite) == .allow }!, paneFolder: project.path)
    let permissions = HostAgentPermissions(applicationDirectory: application, protocolDirectory: protocolDirectory,
        shimDirectory: application.appendingPathComponent("bin"), transportDirectory: root.appendingPathComponent("transport"),
        endpointDirectory: root.appendingPathComponent("transport/endpoint"), profile: profile)
    let configuration = permissions.configurationArguments
    try tomlExpect(configuration.count == 4 && configuration[0] == "-c" && configuration[2] == "-c", "the permission arguments changed shape: \(configuration)")
    let table = try tomlBasicStrings(in: configuration[1])
    try tomlExpect(table.contains { $0.hasSuffix("/project/with \"quote\" and \\slash") },
                   "the permission table lost the exact project path: \(table)")
    let profileName = try readTOMLBasicString(configuration[3].dropFirst("default_permissions=".count))
    try tomlExpect(profileName.value == permissions.profileName && profileName.rest.isEmpty, "default_permissions is not the exact profile name")
}

private func tomlRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "CodexTOML", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

/// The shared encoder on its own: slashes stay slashes, every character that
/// needs an escape gets one TOML defines, and everything reads back exactly.
func checkTOMLStringEscapesOnlyWhatTOMLDefines() throws {
    let samples = ["", "/usr/bin/parley", "a \"quoted\" \\ path", "line\nbreak\ttab\rreturn\u{8}\u{c}",
                   "bell\u{7} escape\u{1b} delete\u{7f} nul\u{0}", "café — 🙂 \u{2028}\u{2029}", "\\/ not an escape"]
    for sample in samples {
        let encoded = TOMLString.basic(sample)
        let read = try readTOMLBasicString(Substring(encoded))
        try tomlExpect(read.value == sample && read.rest.isEmpty, "\(sample.debugDescription) did not read back exactly from \(encoded)")
        try tomlExpect(!encoded.contains("\\/") || sample.contains("\\/"), "a slash was escaped in \(encoded)")
    }
    try tomlExpect(TOMLString.basic("a/b") == "\"a/b\"", "a slash was escaped")
    try tomlExpect(TOMLString.basic("\u{7f}") == "\"\\u007F\"", "DEL was not escaped as TOML requires")
}

@MainActor let codexTOMLChecks: [(String, () throws -> Void)] = [
    ("codex configuration values are valid toml", checkCodexConfigurationValuesAreValidTOML),
    ("toml string escapes only what toml defines", checkTOMLStringEscapesOnlyWhatTOMLDefines),
]
