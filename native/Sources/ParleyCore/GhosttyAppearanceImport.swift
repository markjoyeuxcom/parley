import Darwin
import Foundation

public enum GhosttyAppearanceImportError: LocalizedError, Equatable, Sendable {
    case configurationNotFound
    case configurationTooLarge(String)
    case invalidTextEncoding(String)
    case unreadableConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .configurationNotFound:
            "No Ghostty configuration was found in the standard XDG or macOS locations."
        case let .configurationTooLarge(path):
            "Ghostty appearance was not imported because \(path) exceeds 256 KB."
        case let .invalidTextEncoding(path):
            "Ghostty appearance was not imported because \(path) is not UTF-8 text."
        case let .unreadableConfiguration(path):
            "Ghostty appearance was not imported because \(path) is not a readable regular file."
        }
    }
}

public struct GhosttyAppearanceColors: Codable, Equatable, Sendable {
    public private(set) var background: String?
    public private(set) var foreground: String?
    public private(set) var cursorColor: String?
    public private(set) var cursorText: String?
    public private(set) var selectionBackground: String?
    public private(set) var selectionForeground: String?
    public private(set) var boldColor: String?
    public private(set) var palette: [Int: String]

    public init(
        background: String? = nil,
        foreground: String? = nil,
        cursorColor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        boldColor: String? = nil,
        palette: [Int: String] = [:]
    ) {
        self.background = Self.normalizedHexColor(background)
        self.foreground = Self.normalizedHexColor(foreground)
        self.cursorColor = Self.normalizedHexColor(cursorColor)
        self.cursorText = Self.normalizedHexColor(cursorText)
        self.selectionBackground = Self.normalizedHexColor(selectionBackground)
        self.selectionForeground = Self.normalizedHexColor(selectionForeground)
        self.boldColor = Self.normalizedHexColor(boldColor)
        self.palette = palette.reduce(into: [:]) { result, entry in
            guard 0 ... 255 ~= entry.key,
                  let color = Self.normalizedHexColor(entry.value) else { return }
            result[entry.key] = color
        }
    }

    public var settingCount: Int {
        [
            background,
            foreground,
            cursorColor,
            cursorText,
            selectionBackground,
            selectionForeground,
            boldColor,
        ].compactMap { $0 }.count + palette.count
    }

    fileprivate static func normalizedHexColor(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6,
              hex.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value)
                      || (65 ... 70).contains($0.value)
                      || (97 ... 102).contains($0.value)
              }) else { return nil }
        return "#\(hex)"
    }

    private enum CodingKeys: String, CodingKey {
        case background
        case foreground
        case cursorColor
        case cursorText
        case selectionBackground
        case selectionForeground
        case boldColor
        case palette
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            background: try values.decodeIfPresent(String.self, forKey: .background),
            foreground: try values.decodeIfPresent(String.self, forKey: .foreground),
            cursorColor: try values.decodeIfPresent(String.self, forKey: .cursorColor),
            cursorText: try values.decodeIfPresent(String.self, forKey: .cursorText),
            selectionBackground: try values.decodeIfPresent(String.self, forKey: .selectionBackground),
            selectionForeground: try values.decodeIfPresent(String.self, forKey: .selectionForeground),
            boldColor: try values.decodeIfPresent(String.self, forKey: .boldColor),
            palette: try values.decodeIfPresent([Int: String].self, forKey: .palette) ?? [:]
        )
    }
}

public struct GhosttyAppearanceImport: Codable, Equatable, Sendable {
    public let sourceFiles: [String]
    public let themeDescription: String?
    public let fontFamily: String?
    public let fontSize: Double?
    public let light: GhosttyAppearanceColors
    public let dark: GhosttyAppearanceColors
    public let ignoredSettingCount: Int

    public init(
        sourceFiles: [String],
        themeDescription: String?,
        fontFamily: String?,
        fontSize: Double?,
        light: GhosttyAppearanceColors,
        dark: GhosttyAppearanceColors,
        ignoredSettingCount: Int
    ) {
        self.sourceFiles = Array(
            sourceFiles.compactMap { Self.normalizedDisplayText($0) }.prefix(12)
        )
        self.themeDescription = Self.normalizedDisplayText(themeDescription, maximumLength: 512)
        self.fontFamily = (try? TerminalFontPreference(family: fontFamily, size: nil))?.family
        self.fontSize = (try? TerminalFontPreference(family: nil, size: fontSize))?.size
        self.light = light
        self.dark = dark
        self.ignoredSettingCount = min(max(ignoredSettingCount, 0), 100_000)
    }

    public var importedSettingCount: Int {
        (fontFamily == nil ? 0 : 1)
            + (fontSize == nil ? 0 : 1)
            + light.settingCount
            + dark.settingCount
    }

    public var hasAppearance: Bool {
        importedSettingCount > 0
    }

    private static func normalizedDisplayText(
        _ value: String?,
        maximumLength: Int = 1_024
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumLength,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case sourceFiles
        case themeDescription
        case fontFamily
        case fontSize
        case light
        case dark
        case ignoredSettingCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceFiles: try values.decode([String].self, forKey: .sourceFiles),
            themeDescription: try values.decodeIfPresent(String.self, forKey: .themeDescription),
            fontFamily: try values.decodeIfPresent(String.self, forKey: .fontFamily),
            fontSize: try values.decodeIfPresent(Double.self, forKey: .fontSize),
            light: try values.decode(GhosttyAppearanceColors.self, forKey: .light),
            dark: try values.decode(GhosttyAppearanceColors.self, forKey: .dark),
            ignoredSettingCount: try values.decode(Int.self, forKey: .ignoredSettingCount)
        )
    }
}

public enum GhosttyAppearanceImporter {
    public typealias BuiltInThemeResolver = (String) -> GhosttyAppearanceColors?

    private static let maximumFileBytes = 256 * 1_024
    private static let maximumLines = 4_096

    public static func load(
        homeDirectory: URL,
        environment: [String: String],
        fileManager: FileManager = .default,
        builtInTheme: BuiltInThemeResolver
    ) throws -> GhosttyAppearanceImport {
        let roots = configurationRoots(homeDirectory: homeDirectory, environment: environment)
        let candidates = roots.flatMap { root in
            [
                root.appendingPathComponent("config.ghostty", isDirectory: false),
                root.appendingPathComponent("config", isDirectory: false),
            ]
        }
        var state = ImportState()
        var foundConfiguration = false
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            foundConfiguration = true
            let source = try readText(candidate, fileManager: fileManager)
            state.recordSource(source.url.path)
            parseRootConfiguration(source.text, state: &state)
        }
        guard foundConfiguration else {
            throw GhosttyAppearanceImportError.configurationNotFound
        }

        let selections = themeSelections(state.themeDescription)
        let lightTheme = try resolveTheme(
            named: selections.light,
            roots: roots,
            fileManager: fileManager,
            builtInTheme: builtInTheme,
            state: &state
        )
        let darkTheme: GhosttyAppearanceColors?
        if selections.dark == selections.light {
            darkTheme = lightTheme
        } else {
            darkTheme = try resolveTheme(
                named: selections.dark,
                roots: roots,
                fileManager: fileManager,
                builtInTheme: builtInTheme,
                state: &state
            )
        }
        return GhosttyAppearanceImport(
            sourceFiles: state.sourceFiles,
            themeDescription: state.themeDescription,
            fontFamily: state.fontFamily,
            fontSize: state.fontSize,
            light: state.direct.applying(to: lightTheme ?? GhosttyAppearanceColors()),
            dark: state.direct.applying(to: darkTheme ?? GhosttyAppearanceColors()),
            ignoredSettingCount: state.ignoredSettingCount
        )
    }

    private struct ImportState {
        var sourceFiles: [String] = []
        var sourceFileSet: Set<String> = []
        var themeDescription: String?
        var fontFamily: String?
        var fontSize: Double?
        var direct = ColorAccumulator()
        var ignoredSettingCount = 0

        mutating func recordSource(_ path: String) {
            guard sourceFiles.count < 12, sourceFileSet.insert(path).inserted else { return }
            sourceFiles.append(path)
        }
    }

    private struct ColorAccumulator {
        var background: String?
        var foreground: String?
        var cursorColor: String?
        var cursorText: String?
        var selectionBackground: String?
        var selectionForeground: String?
        var boldColor: String?
        var palette: [Int: String] = [:]
        var resetKeys: Set<String> = []
        var paletteWasReset = false

        var colors: GhosttyAppearanceColors {
            GhosttyAppearanceColors(
                background: background,
                foreground: foreground,
                cursorColor: cursorColor,
                cursorText: cursorText,
                selectionBackground: selectionBackground,
                selectionForeground: selectionForeground,
                boldColor: boldColor,
                palette: palette
            )
        }

        func applying(to base: GhosttyAppearanceColors) -> GhosttyAppearanceColors {
            func value(_ key: String, _ override: String?, _ inherited: String?) -> String? {
                if resetKeys.contains(key) { return nil }
                return override ?? inherited
            }
            let mergedPalette: [Int: String]
            if paletteWasReset {
                mergedPalette = palette
            } else {
                mergedPalette = base.palette.merging(palette) { _, replacement in replacement }
            }
            return GhosttyAppearanceColors(
                background: value("background", background, base.background),
                foreground: value("foreground", foreground, base.foreground),
                cursorColor: value("cursor-color", cursorColor, base.cursorColor),
                cursorText: value("cursor-text", cursorText, base.cursorText),
                selectionBackground: value(
                    "selection-background",
                    selectionBackground,
                    base.selectionBackground
                ),
                selectionForeground: value(
                    "selection-foreground",
                    selectionForeground,
                    base.selectionForeground
                ),
                boldColor: value("bold-color", boldColor, base.boldColor),
                palette: mergedPalette
            )
        }
    }

    private static func configurationRoots(
        homeDirectory: URL,
        environment: [String: String]
    ) -> [URL] {
        let xdgRoot: URL
        if let configured = environment["XDG_CONFIG_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty,
            configured.hasPrefix("/")
        {
            xdgRoot = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            xdgRoot = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }
        return [
            xdgRoot.appendingPathComponent("ghostty", isDirectory: true),
            homeDirectory.appendingPathComponent(
                "Library/Application Support/com.mitchellh.ghostty",
                isDirectory: true
            ),
        ]
    }

    private static func readText(
        _ requestedURL: URL,
        fileManager: FileManager
    ) throws -> (url: URL, text: String) {
        let standardized = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        let url: URL
        if let resolved = realpath(standardized.path, nil) {
            defer { free(resolved) }
            url = URL(fileURLWithPath: String(cString: resolved), isDirectory: false)
        } else {
            url = standardized
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            throw GhosttyAppearanceImportError.unreadableConfiguration(url.path)
        }
        if let fileSize = values.fileSize, fileSize > maximumFileBytes {
            throw GhosttyAppearanceImportError.configurationTooLarge(url.path)
        }
        guard let data = fileManager.contents(atPath: url.path) else {
            throw GhosttyAppearanceImportError.unreadableConfiguration(url.path)
        }
        guard data.count <= maximumFileBytes else {
            throw GhosttyAppearanceImportError.configurationTooLarge(url.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GhosttyAppearanceImportError.invalidTextEncoding(url.path)
        }
        return (url, text)
    }

    private static func parseRootConfiguration(_ text: String, state: inout ImportState) {
        for line in parsedLines(text, ignoredSettingCount: &state.ignoredSettingCount) {
            switch line.key {
            case "font-family":
                if line.value.isEmpty {
                    state.fontFamily = nil
                } else if let family = (try? TerminalFontPreference(
                    family: line.value,
                    size: nil
                ))?.family {
                    state.fontFamily = family
                } else {
                    state.ignoredSettingCount += 1
                }
            case "font-size":
                if line.value.isEmpty {
                    state.fontSize = nil
                } else if let size = Double(line.value),
                          (try? TerminalFontPreference(family: nil, size: size)) != nil {
                    state.fontSize = size
                } else {
                    state.ignoredSettingCount += 1
                }
            case "theme":
                if line.value.isEmpty {
                    state.themeDescription = nil
                } else if normalizedThemeDescription(line.value) != nil {
                    state.themeDescription = line.value
                } else {
                    state.ignoredSettingCount += 1
                }
            default:
                if !applyColor(line, to: &state.direct) {
                    state.ignoredSettingCount += 1
                }
            }
        }
    }

    private static func parseTheme(_ text: String, ignoredSettingCount: inout Int) -> GhosttyAppearanceColors {
        var colors = ColorAccumulator()
        for line in parsedLines(text, ignoredSettingCount: &ignoredSettingCount) {
            guard applyColor(line, to: &colors) else {
                ignoredSettingCount += 1
                continue
            }
        }
        return colors.colors
    }

    private struct ParsedLine {
        let key: String
        let value: String
    }

    private static func parsedLines(
        _ text: String,
        ignoredSettingCount: inout Int
    ) -> [ParsedLine] {
        var result: [ParsedLine] = []
        let lines = text.components(separatedBy: .newlines)
        if lines.count > maximumLines {
            ignoredSettingCount += lines.count - maximumLines
        }
        for rawLine in lines.prefix(maximumLines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else {
                ignoredSettingCount += 1
                continue
            }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            guard !key.isEmpty,
                  key.count <= 128,
                  value.count <= 4_096,
                  key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else {
                ignoredSettingCount += 1
                continue
            }
            result.append(ParsedLine(key: key, value: value))
        }
        return result
    }

    private static func applyColor(_ line: ParsedLine, to colors: inout ColorAccumulator) -> Bool {
        if line.key == "palette" {
            if line.value.isEmpty {
                colors.palette.removeAll()
                colors.paletteWasReset = true
                return true
            }
            guard let equals = line.value.firstIndex(of: "="),
                  let index = Int(line.value[..<equals]),
                  0 ... 255 ~= index,
                  let color = GhosttyAppearanceColors.normalizedHexColor(
                      String(line.value[line.value.index(after: equals)...])
                  ) else { return false }
            colors.palette[index] = color
            return true
        }

        let color: String?
        if line.value.isEmpty {
            color = nil
        } else {
            guard let valid = GhosttyAppearanceColors.normalizedHexColor(line.value) else {
                return false
            }
            color = valid
        }
        switch line.key {
        case "background": colors.background = color
        case "foreground": colors.foreground = color
        case "cursor-color": colors.cursorColor = color
        case "cursor-text": colors.cursorText = color
        case "selection-background": colors.selectionBackground = color
        case "selection-foreground": colors.selectionForeground = color
        case "bold-color": colors.boldColor = color
        default: return false
        }
        if line.value.isEmpty {
            colors.resetKeys.insert(line.key)
        } else {
            colors.resetKeys.remove(line.key)
        }
        return true
    }

    private static func normalizedThemeDescription(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 512,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private static func themeSelections(_ value: String?) -> (light: String?, dark: String?) {
        guard let value = value.flatMap(normalizedThemeDescription) else { return (nil, nil) }
        let components = value.split(separator: ",", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        var light: String?
        var dark: String?
        var explicitMode = false
        for component in components {
            if component.hasPrefix("light:") {
                explicitMode = true
                light = normalizedThemeDescription(String(component.dropFirst("light:".count)))
            } else if component.hasPrefix("dark:") {
                explicitMode = true
                dark = normalizedThemeDescription(String(component.dropFirst("dark:".count)))
            }
        }
        if explicitMode {
            return (light, dark)
        }
        return (value, value)
    }

    private static func resolveTheme(
        named name: String?,
        roots: [URL],
        fileManager: FileManager,
        builtInTheme: BuiltInThemeResolver,
        state: inout ImportState
    ) throws -> GhosttyAppearanceColors? {
        guard let name else { return nil }
        var candidates: [URL] = []
        if name.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: name, isDirectory: false))
        } else if !name.contains("/"), name != ".", name != "..", let xdgRoot = roots.first {
            candidates.append(
                xdgRoot.appendingPathComponent("themes", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
            )
        }
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            let source = try readText(candidate, fileManager: fileManager)
            state.recordSource(source.url.path)
            return parseTheme(source.text, ignoredSettingCount: &state.ignoredSettingCount)
        }
        if let theme = builtInTheme(name) {
            return theme
        }
        state.ignoredSettingCount += 1
        return nil
    }
}
