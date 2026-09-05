import Darwin
import Foundation
import ParleyCore

private enum RecipeCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

private func recipeExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RecipeCheckFailure.failed(message) }
}

private func recipeRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw RecipeCheckFailure.failed(message) }
    return value
}

private func recipeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-recipes-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    return directory
}

private let originalIDs = ["plan-review", "implementation-review", "adversarial-bug-hunt", "compare-recommendations"]

private func writeDocument(version: Int, recipes: [[String: Any]], to file: URL, permissions: Int = 0o600) throws {
    let data = try JSONSerialization.data(withJSONObject: ["version": version, "recipes": recipes], options: [.sortedKeys])
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
}

private func recipeObject(_ recipe: HandoffRecipe, instructions: String? = nil) -> [String: Any] {
    ["id": recipe.id, "name": recipe.name, "kind": recipe.kind.rawValue, "instructions": instructions ?? recipe.instructions]
}

private func permissions(of file: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
}

private func loadedDocument(_ file: URL) throws -> (version: Int, ids: [String]) {
    let object = try recipeRequire(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], "recipe file is not a JSON object")
    let version = try recipeRequire(object["version"] as? Int, "recipe file has no version")
    let recipes = try recipeRequire(object["recipes"] as? [[String: Any]], "recipe file has no recipes")
    return (version, recipes.compactMap { $0["id"] as? String })
}

func checkReviewAndCorrectRecipeIsAPromptTemplateOnly() throws {
    try recipeExpect(HandoffRecipe.defaults.count == 5, "expected exactly five built-in recipes, found \(HandoffRecipe.defaults.count)")
    try recipeExpect(HandoffRecipe.defaults.map(\.id).prefix(4).elementsEqual(originalIDs), "the original four recipes changed identity or order")
    let matches = HandoffRecipe.defaults.filter { $0.id == "review-and-correct" }
    try recipeExpect(matches.count == 1, "expected exactly one Review and correct recipe, found \(matches.count)")
    let recipe = try recipeRequire(matches.first, "no Review and correct recipe")
    try recipeExpect(recipe.name == "Review and correct", "recipe name is \(recipe.name)")
    try recipeExpect(recipe.kind == .delegate, "recipe kind is \(recipe.kind); the practice starts with a tracked delegation")
    try recipeExpect(HandoffRecipe.defaults.last?.id == recipe.id, "the new recipe is not appended after the existing four")
    try recipeExpect(HandoffRecipeKind.allCases.map(\.rawValue) == ["ask", "askMany", "delegate"], "a new recipe kind was introduced")

    // Routing and render bounds are the ordinary recipe rules.
    try recipeExpect(recipe.instructions.contains("{{targets}}"), "the recipe lost explicit {{targets}} routing")
    let rendered = try recipe.render(targets: ["%claude", "%codex"])
    try recipeExpect(rendered.contains("%claude, %codex") && !rendered.contains("{{targets}}"), "targets were not substituted: \(rendered.prefix(120))")
    try recipeExpect(rendered.count <= RelayText.maximumCharacters, "the rendered recipe exceeds the relay bound")
    try recipeExpect((try? recipe.render(targets: [])) == nil, "the recipe rendered without an explicit target")

    // The practice, in order, and the evidence headings the target must use.
    let text = recipe.instructions
    let lowered = text.lowercased()
    for phrase in [
        "parley delegate", "parley progress current", "parley done current", "--file <path>",
        "different vendor", "--parent <handoff-id>", "verif",
    ] {
        try recipeExpect(lowered.contains(phrase), "the recipe does not guide the step containing \(phrase)")
    }
    for step in ["delegate", "progress", "result", "review", "correction", "independent"] {
        try recipeExpect(lowered.contains(step), "the recipe omits the practice step \(step)")
    }
    let delegateIndex = try recipeRequire(lowered.range(of: "parley delegate ")?.lowerBound, "no delegate step")
    let progressIndex = try recipeRequire(lowered.range(of: "parley progress current")?.lowerBound, "no progress step")
    let reviewIndex = try recipeRequire(lowered.range(of: "different vendor")?.lowerBound, "no review step")
    let correctionIndex = try recipeRequire(lowered.range(of: "--parent <handoff-id>")?.lowerBound, "no linked corrections step")
    let verifyIndex = try recipeRequire(lowered.range(of: "verif", range: correctionIndex..<lowered.endIndex)?.lowerBound, "no independent verification after corrections")
    try recipeExpect(delegateIndex < progressIndex && progressIndex < reviewIndex && reviewIndex < correctionIndex && correctionIndex < verifyIndex, "the practice steps are not in the documented order")
    for heading in CompletionEvidenceSection.allCases.map(\.heading) {
        try recipeExpect(text.contains("## \(heading)"), "the recipe does not ask for the \(heading) heading")
    }
    try recipeExpect(lowered.contains("command") && lowered.contains("claimed outcome") && lowered.contains("reason"), "the recipe does not ask for each command, its claimed outcome, and the reason")
    try recipeExpect(lowered.contains("guidance") && lowered.contains("not a required sequence"), "the recipe does not present the practice as guidance")
    try recipeExpect(lowered.contains("agent-declared") || lowered.contains("claim"), "the recipe does not name progress and evidence as claims")

    // Prompt-only: no outcome claims, no state or automation vocabulary, no extra model.
    for banned in ["passed", "verified", "trusted", "successful"] {
        try recipeExpect(!lowered.contains(banned), "the recipe claims an outcome with the word \(banned)")
    }
    for banned in ["phase", "state machine", "automatic", "transition", "executor", "workflow", "window", "advance"] {
        try recipeExpect(!lowered.contains(banned), "the recipe carries automation or state vocabulary: \(banned)")
    }
    let encoded = try recipeRequire(try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any], "recipe did not encode")
    try recipeExpect(Set(encoded.keys) == ["id", "name", "kind", "instructions"], "the recipe model carries fields beyond a prompt template: \(encoded.keys.sorted())")

    // Editable like every other recipe; name and kind stay fixed.
    let directory = try recipeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HandoffRecipeStore(file: directory.appendingPathComponent("handoff-recipes.json"))
    let edited = HandoffRecipe(id: recipe.id, name: recipe.name, kind: recipe.kind, instructions: "Shorter practice for {{targets}}.")
    try store.save(edited)
    let afterEdit = try store.recipes()
    try recipeExpect(afterEdit.first(where: { $0.id == recipe.id })?.instructions == edited.instructions, "the recipe is not editable")
    try recipeExpect((try? store.save(HandoffRecipe(id: recipe.id, name: "Renamed", kind: recipe.kind, instructions: edited.instructions))) == nil, "the recipe name was allowed to change")
    try recipeExpect((try? store.save(HandoffRecipe(id: recipe.id, name: recipe.name, kind: .ask, instructions: edited.instructions))) == nil, "the recipe kind was allowed to change")
    try store.restoreDefaults()
    let afterRestore = try store.recipes()
    try recipeExpect(afterRestore == HandoffRecipe.defaults, "restore defaults did not restore all five")
}

func checkHandoffRecipeStoreMigratesOlderDocumentsAdditively() throws {
    let directory = try recipeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("handoff-recipes.json")
    let originals = HandoffRecipe.defaults.filter { originalIDs.contains($0.id) }
    let editedPlan = "Edited plan review with {{targets}} kept locally."
    let editedHunt = "Edited hunt for {{targets}}."

    // A valid older four-recipe document loads with its edits intact and backfills only the new recipe.
    try writeDocument(version: 1, recipes: originals.map { recipe in
        recipeObject(recipe, instructions: recipe.id == "plan-review" ? editedPlan : (recipe.id == "adversarial-bug-hunt" ? editedHunt : nil))
    }, to: file)
    let store = HandoffRecipeStore(file: file)
    let loaded = try store.recipes()
    try recipeExpect(loaded.map(\.id) == HandoffRecipe.defaults.map(\.id), "migration did not produce the five built-ins in default order: \(loaded.map(\.id))")
    try recipeExpect(loaded.first(where: { $0.id == "plan-review" })?.instructions == editedPlan, "migration lost a local edit to plan-review")
    try recipeExpect(loaded.first(where: { $0.id == "adversarial-bug-hunt" })?.instructions == editedHunt, "migration lost a local edit to adversarial-bug-hunt")
    try recipeExpect(loaded.first(where: { $0.id == "implementation-review" }) == HandoffRecipe.defaults.first(where: { $0.id == "implementation-review" }), "an unedited older recipe was altered")
    try recipeExpect(loaded.first(where: { $0.id == "review-and-correct" }) == HandoffRecipe.defaults.last, "the new recipe was not backfilled from its default")
    let persisted = try loadedDocument(file)
    try recipeExpect(persisted.version == 2 && persisted.ids == HandoffRecipe.defaults.map(\.id), "migration was not persisted as a version 2 document: \(persisted)")
    try recipeExpect(permissions(of: file) == 0o600, "migration changed the file permissions: \(String(describing: permissions(of: file)))")
    let secondLoad = try HandoffRecipeStore(file: file).recipes()
    try recipeExpect(secondLoad == loaded, "a second load after migration differed")
    let saved = HandoffRecipe(id: "compare-recommendations", name: "Compare recommendations", kind: .askMany, instructions: "Compare with {{targets}} again.")
    try store.save(saved)
    let afterSave = try store.recipes()
    try recipeExpect(afterSave.first(where: { $0.id == saved.id })?.instructions == saved.instructions && afterSave.first(where: { $0.id == "plan-review" })?.instructions == editedPlan, "saving after migration lost an edit")

    // Missing built-ins are still refused as incomplete, at either version.
    try writeDocument(version: 1, recipes: originals.dropLast().map { recipeObject($0) }, to: file)
    try recipeExpect((try? HandoffRecipeStore(file: file).recipes()) == nil, "an older document missing one of its built-ins was accepted")
    try writeDocument(version: 2, recipes: originals.map { recipeObject($0) }, to: file)
    try recipeExpect((try? HandoffRecipeStore(file: file).recipes()) == nil, "a current document missing the new built-in was accepted")
    try writeDocument(version: 1, recipes: HandoffRecipe.defaults.map { recipeObject($0) }, to: file)
    try recipeExpect((try? HandoffRecipeStore(file: file).recipes()) == nil, "an older document with an unexpected recipe was accepted")
    try writeDocument(version: 3, recipes: HandoffRecipe.defaults.map { recipeObject($0) }, to: file)
    try recipeExpect((try? HandoffRecipeStore(file: file).recipes()) == nil, "an unsupported future version was accepted")
    try writeDocument(version: 2, recipes: HandoffRecipe.defaults.map { recipeObject($0) }, to: file)
    let complete = try HandoffRecipeStore(file: file).recipes()
    try recipeExpect(complete == HandoffRecipe.defaults, "a complete version 2 document did not load")

    // Ownership and permission validation is unchanged.
    try writeDocument(version: 1, recipes: originals.map { recipeObject($0) }, to: file, permissions: 0o640)
    try recipeExpect((try? HandoffRecipeStore(file: file).recipes()) == nil, "a group-readable recipe file was accepted")
    try FileManager.default.removeItem(at: file)
    let absent = try HandoffRecipeStore(file: file).recipes()
    try recipeExpect(absent == HandoffRecipe.defaults, "a missing file did not serve the five defaults")
    let fresh = HandoffRecipeStore(file: file)
    try fresh.restoreDefaults()
    let restored = try loadedDocument(file)
    try recipeExpect(restored.version == 2 && restored.ids.count == 5 && permissions(of: file) == 0o600, "restore defaults did not write a version 2 owner-only document")
}

func checkReviewAndCorrectGuidanceIsDocumentedAsPractice() throws {
    let searchable = ParleyHelpGuide.topics.map(\.searchableText).joined(separator: "\n").lowercased()
    for concept in [
        "review and correct", "guidance, not a required sequence", "milestone", "different vendor",
        "request changes", "independent", "## implemented", "## tested", "## unable to test",
    ] {
        try recipeExpect(searchable.contains(concept), "the in-app help omitted \(concept)")
    }
    let recipeHelp = ParleyHelpGuide.topics.flatMap(\.sections).first(where: { $0.id == "lead-recipes" })
    let recipeSection = try recipeRequire(recipeHelp, "the recipe help section is missing")
    let recipeText = ([recipeSection.title] + recipeSection.paragraphs + recipeSection.items + recipeSection.commands.flatMap { [$0.command, $0.explanation] })
        .joined(separator: "\n")
        .lowercased()
    try recipeExpect(recipeText.contains("review and correct"), "the recipe list in help does not name Review and correct")
    for banned in ["state machine", "automatic transition", "executor"] {
        try recipeExpect(!recipeText.contains(banned) || recipeText.contains("no \(banned)") || recipeText.contains("not "), "recipe help describes automation: \(banned)")
    }
    try recipeExpect(AgentProtocol.version == "18", "recipe checks did not use the current shared protocol")
}

private func targetPane(_ id: String, _ kind: PaneKind, _ name: String) -> WorkbenchPane {
    WorkbenchPane(
        id: id, kind: kind, customName: name, terminalTitle: "", cwd: "/private/project", currentCommand: "x",
        isActive: false, workspaceID: "@targets", relayEnabled: true,
        protocolVersion: AgentProtocol.version, workspaceName: "Targets", inputAvailable: true
    )
}

func checkReviewAndCorrectRequiresTwoTargetsFromDifferentVendors() throws {
    func recipe(_ id: String) throws -> HandoffRecipe {
        try recipeRequire(HandoffRecipe.defaults.first(where: { $0.id == id }), "missing built-in \(id)")
    }
    let reviewAndCorrect = try recipe("review-and-correct")
    let bugHunt = try recipe("adversarial-bug-hunt")
    let compare = try recipe("compare-recommendations")
    let planReview = try recipe("plan-review")

    // Derived requirements: not stored, and unchanged for every other recipe.
    try recipeExpect(
        reviewAndCorrect.targetRequirements == HandoffRecipeTargetRequirements(minimumTargets: 2, minimumDistinctVendors: 2)
            && reviewAndCorrect.targetRequirements.allowsMultiple,
        "Review and correct does not require two targets from two vendors: \(reviewAndCorrect.targetRequirements)"
    )
    try recipeExpect(
        bugHunt.targetRequirements == HandoffRecipeTargetRequirements(minimumTargets: 1, minimumDistinctVendors: 1) && !bugHunt.targetRequirements.allowsMultiple,
        "an ordinary delegate recipe stopped being single-select"
    )
    try recipeExpect(
        compare.targetRequirements == HandoffRecipeTargetRequirements(minimumTargets: 2, minimumDistinctVendors: 1) && compare.targetRequirements.allowsMultiple,
        "Compare behaviour changed"
    )
    try recipeExpect(planReview.targetRequirements == HandoffRecipeTargetRequirements(minimumTargets: 1, minimumDistinctVendors: 1), "Ask recipe behaviour changed")
    let encoded = try recipeRequire(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reviewAndCorrect)) as? [String: Any], "recipe did not encode")
    try recipeExpect(Set(encoded.keys) == ["id", "name", "kind", "instructions"], "requirements leaked into the stored recipe schema: \(encoded.keys.sorted())")

    // Pure render minimum follows the requirement.
    try recipeExpect((try? reviewAndCorrect.render(targets: ["%claude"])) == nil, "Review and correct rendered with a single target")
    try recipeExpect((try? reviewAndCorrect.render(targets: ["%claude", "%codex"])) != nil, "Review and correct did not render with two targets")
    try recipeExpect((try? bugHunt.render(targets: ["%claude"])) != nil, "an ordinary delegate recipe no longer renders with one target")
    try recipeExpect((try? compare.render(targets: ["%claude"])) == nil && (try? compare.render(targets: ["%a", "%b"])) != nil, "Compare render minimum changed")

    // Eligibility and selection rules over real panes.
    let claudeA = targetPane("%claude-a", .claude, "Claude A")
    let claudeB = targetPane("%claude-b", .claude, "Claude B")
    let codex = targetPane("%codex", .codex, "Codex")
    let agy = targetPane("%agy", .agy, "Agy")
    try recipeExpect(!HandoffRecipeTargeting.canSatisfy(reviewAndCorrect, with: []), "no candidates satisfied Review and correct")
    try recipeExpect(!HandoffRecipeTargeting.canSatisfy(reviewAndCorrect, with: [claudeA]), "one candidate satisfied Review and correct")
    try recipeExpect(!HandoffRecipeTargeting.canSatisfy(reviewAndCorrect, with: [claudeA, claudeB]), "two same-vendor candidates satisfied Review and correct")
    try recipeExpect(HandoffRecipeTargeting.canSatisfy(reviewAndCorrect, with: [claudeA, codex]), "two different vendors did not satisfy Review and correct")
    try recipeExpect(HandoffRecipeTargeting.canSatisfy(reviewAndCorrect, with: [claudeA, claudeB, agy]), "three candidates spanning two vendors did not satisfy Review and correct")
    try recipeExpect(HandoffRecipeTargeting.canSatisfy(bugHunt, with: [claudeA]), "an ordinary delegate recipe lost single-target eligibility")
    try recipeExpect(!HandoffRecipeTargeting.canSatisfy(compare, with: [claudeA]) && HandoffRecipeTargeting.canSatisfy(compare, with: [claudeA, claudeB]), "Compare eligibility changed")

    try recipeExpect(HandoffRecipeTargeting.rejection(for: reviewAndCorrect, selected: [claudeA]) != nil, "a single selected target was accepted for Review and correct")
    let sameVendor = try recipeRequire(HandoffRecipeTargeting.rejection(for: reviewAndCorrect, selected: [claudeA, claudeB]), "a same-vendor-only selection was accepted for Review and correct")
    try recipeExpect(sameVendor.lowercased().contains("different vendors") && sameVendor.contains("Claude"), "the same-vendor rejection is not explicit: \(sameVendor)")
    try recipeExpect(HandoffRecipeTargeting.rejection(for: reviewAndCorrect, selected: [claudeA, codex]) == nil, "two different vendors were rejected")
    try recipeExpect(HandoffRecipeTargeting.rejection(for: reviewAndCorrect, selected: [claudeA, claudeB, codex]) == nil, "two or more panes spanning two vendors were rejected")
    try recipeExpect(HandoffRecipeTargeting.rejection(for: compare, selected: [claudeA]) == "Compare needs at least two selected panes.", "Compare's selection copy changed")
    try recipeExpect(HandoffRecipeTargeting.rejection(for: compare, selected: [claudeA, claudeB]) == nil, "Compare started requiring distinct vendors")
    try recipeExpect(HandoffRecipeTargeting.rejection(for: bugHunt, selected: [claudeA]) == nil, "an ordinary delegate recipe rejected its single target")

    // Honest copy for the picker and for the unavailable case; the lead stays excluded by the caller.
    let picker = HandoffRecipeTargeting.pickerMessage(for: reviewAndCorrect).lowercased()
    try recipeExpect(picker.contains("different vendors") && picker.contains("lead"), "the picker copy does not explain the two-vendor rule and the lead exclusion: \(picker)")
    try recipeExpect(HandoffRecipeTargeting.pickerMessage(for: compare) == "Choose at least two explicit panes. They will answer independently.", "Compare picker copy changed")
    try recipeExpect(HandoffRecipeTargeting.pickerMessage(for: bugHunt) == "Choose the exact agent pane the lead should use.", "single-select picker copy changed")
    try recipeExpect(HandoffRecipeTargeting.unavailableMessage(for: reviewAndCorrect).lowercased().contains("different vendors"), "the unavailable copy does not explain the two-vendor rule")
    try recipeExpect(HandoffRecipeTargeting.unavailableMessage(for: compare) == "Open at least two ready agent panes other than the lead.", "Compare unavailable copy changed")
    try recipeExpect(HandoffRecipeTargeting.unavailableMessage(for: bugHunt) == "Open a ready agent pane other than the lead.", "single-select unavailable copy changed")
    try recipeExpect(AgentProtocol.version == "18", "targeting checks did not use the current shared protocol")
}
