import Foundation
import ParleyCore

private func configExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ConfigurationLoad", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func configSource(_ folder: String, _ file: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(folder).appendingPathComponent(file)
    return try String(contentsOf: url, encoding: .utf8)
}

/// An unreadable configuration file is copied beside itself, never moved or
/// overwritten, and a second copy in the same second gets its own name.
func checkConfigurationPreservationKeepsTheFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-config-load-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("handoff-recipes.json")
    let bytes = Data("{ not json".utf8)
    try bytes.write(to: file)
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let first = try ConfigurationPreservation.preserve(file: file, now: now)
    try configExpect(first.lastPathComponent.hasPrefix("handoff-recipes.json.unreadable-"), "the copy is not named after the store: \(first.lastPathComponent)")
    try configExpect(try Data(contentsOf: first) == bytes, "the copy does not hold the unreadable bytes")
    try configExpect(try Data(contentsOf: file) == bytes, "the original was changed")
    let second = try ConfigurationPreservation.preserve(file: file, now: now)
    try configExpect(second != first && FileManager.default.fileExists(atPath: second.path), "a second copy in the same second overwrote the first")
    try configExpect(try Data(contentsOf: first) == bytes, "the first copy was overwritten")
    do {
        _ = try ConfigurationPreservation.preserve(file: root.appendingPathComponent("missing.json"), now: now)
        throw NSError(domain: "ConfigurationLoad", code: 2, userInfo: [NSLocalizedDescriptionKey: "preserving a missing file succeeded"])
    } catch let error as NSError where error.domain != "ConfigurationLoad" {
        // A missing file is not an unreadable one; the caller records no copy.
    }
}

/// An unreadable preference value moves to its `.unreadable` key, so the next
/// save does not write defaults over it, and a missing key records nothing.
func checkConfigurationPreservationMovesThePreference() throws {
    let suite = "com.markjoyeux.parley.checks.configuration-load"
    guard let defaults = UserDefaults(suiteName: suite) else { throw NSError(domain: "ConfigurationLoad", code: 3, userInfo: [NSLocalizedDescriptionKey: "no suite"]) }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let bytes = Data("garbage".utf8)
    defaults.set(bytes, forKey: "parley.terminalFontPreference")
    let kept = ConfigurationPreservation.preserve(preferenceKey: "parley.terminalFontPreference", in: defaults)
    try configExpect(kept == "parley.terminalFontPreference.unreadable", "the preserved key is \(kept ?? "nil")")
    try configExpect(defaults.data(forKey: "parley.terminalFontPreference") == nil, "the unreadable value is still under the live key")
    try configExpect(defaults.data(forKey: "parley.terminalFontPreference.unreadable") == bytes, "the bytes were not kept")
    try configExpect(ConfigurationPreservation.preserve(preferenceKey: "parley.absent", in: defaults) == nil, "a missing key reported a copy")
}

/// Every store names its location and fallback, and the issue summary carries
/// the reason, the fallback and where the bytes went.
func checkConfigurationIssueSummariesAreComplete() throws {
    for store in ConfigurationStore.allCases {
        try configExpect(!store.title.isEmpty && !store.fallback.isEmpty, "\(store.rawValue) lacks a title or fallback")
        switch store.location {
        case let .file(name): try configExpect(name.hasSuffix(".json"), "\(store.rawValue) names a non-JSON file")
        case let .preference(key): try configExpect(key.hasPrefix("parley."), "\(store.rawValue) names a key outside parley.")
        }
    }
    let kept = ConfigurationLoadIssue(store: .handoffRecipes, reason: "The data is not valid JSON.", preservedCopy: "/tmp/handoff-recipes.json.unreadable-1")
    try configExpect(kept.summary.contains("Recipes could not be read (handoff-recipes.json): The data is not valid JSON.")
                     && kept.summary.contains("built-in recipe texts") && kept.summary.contains("kept as /tmp/handoff-recipes.json.unreadable-1"),
                     "the summary lost a part: \(kept.summary)")
    let lost = ConfigurationLoadIssue(store: .favouriteFolders, reason: "x", preservedCopy: nil)
    try configExpect(lost.summary.hasSuffix("Nothing was changed on disk."), "a copy that could not be made is not said: \(lost.summary)")
}

/// AppModel reports every store it loads with a fallback instead of deleting
/// the value or overwriting it, and an unreadable layouts file no longer takes
/// the terminal stack down.
func checkAppModelReportsUnreadableStores() throws {
    let source = try configSource("ParleyNative", "AppModel.swift")
    for store in ConfigurationStore.allCases {
        try configExpect(source.contains("ConfigurationLoadIssue(store: .\(store.rawValue),"), "AppModel never records an issue for \(store.rawValue)")
    }
    for forbidden in [
        "(try? workspaceRegistry.records()) ?? []",
        "(try? recipeStore.recipes()) ?? HandoffRecipe.defaults",
        "(try? permissionProfileStore.profiles())",
        "let decoded = try? JSONDecoder().decode(WorkspaceContinuityState.self",
    ] {
        try configExpect(!source.contains(forbidden), "AppModel still silently falls back on a store: \(forbidden)")
    }
    // The launch loads keep an unreadable value aside instead of removing
    // it; the setters may still remove a key when the person chooses the
    // default, which is a choice, not a fallback.
    for key in ["terminalFontPreferenceKey", "terminalAppearanceImportKey", "terminalSurfacePreferenceKey", "workspaceContinuityKey"] {
        try configExpect(source.contains("ConfigurationPreservation.preserve(preferenceKey: Self.\(key), in: preferences)"),
                         "the launch load of \(key) does not keep an unreadable value aside")
    }
    try configExpect(source.contains("savedLayouts = try layoutStore.layouts()\n            } catch {"),
                     "an unreadable workspace-layouts.json is not handled as one store")
    let settings = try configSource("ParleyNative", "ParleySettingsView.swift")
    try configExpect(settings.contains("Section(\"Configuration\")") && settings.contains("model.configurationLoadIssues"),
                     "Settings › General does not show configuration load issues")
    let status = try configSource("ParleyNative", "StatusCenterView.swift")
    try configExpect(status.contains("model.configurationLoadIssues"), "Status Center › Health does not show configuration load issues")
}

@MainActor let configurationLoadChecks: [(String, () throws -> Void)] = [
    ("configuration preservation keeps the file", checkConfigurationPreservationKeepsTheFile),
    ("configuration preservation moves the preference", checkConfigurationPreservationMovesThePreference),
    ("configuration issue summaries are complete", checkConfigurationIssueSummariesAreComplete),
    ("app model reports unreadable stores", checkAppModelReportsUnreadableStores),
]
