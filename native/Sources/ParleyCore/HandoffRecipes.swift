import Darwin
import Foundation

public enum HandoffRecipeKind: String, CaseIterable, Codable, Equatable, Sendable {
    case ask
    case askMany
    case delegate

    public var label: String {
        switch self {
        case .ask: "Consult"
        case .askMany: "Compare"
        case .delegate: "Delegate"
        }
    }

    public func isAllowed(by policy: WorkspaceAutomationPolicy) -> Bool {
        switch self {
        case .ask, .askMany: policy != .off
        case .delegate: policy == .askAndDelegate
        }
    }
}

public struct HandoffRecipe: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: HandoffRecipeKind
    public let instructions: String

    public init(id: String, name: String, kind: HandoffRecipeKind, instructions: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.instructions = instructions
    }

    public func render(targets: [String]) throws -> String {
        let cleanedTargets = targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let requirements = targetRequirements
        guard cleanedTargets.count >= requirements.minimumTargets else {
            throw HandoffRecipeError.invalid(
                requirements.minimumDistinctVendors > 1
                    ? "Review and correct needs at least two explicit targets from different vendors."
                    : (kind == .askMany ? "Compare needs at least two explicit targets." : "Choose one explicit target.")
            )
        }
        let renderedTargets = cleanedTargets.joined(separator: ", ")
        let rendered = instructions.replacingOccurrences(of: "{{targets}}", with: renderedTargets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rendered.isEmpty else { throw HandoffRecipeError.invalid("Recipe instructions cannot be empty.") }
        guard rendered.count <= RelayText.maximumCharacters else {
            throw HandoffRecipeError.invalid("Rendered recipe instructions are too long.")
        }
        return rendered
    }

    public static let defaults: [HandoffRecipe] = [
        HandoffRecipe(
            id: "plan-review",
            name: "Plan review",
            kind: .ask,
            instructions: "Review the current plan with {{targets}} using Parley's correlated Ask. Judge the response yourself, adopt only sound additions, explain any rejected advice, then continue the plan."
        ),
        HandoffRecipe(
            id: "implementation-review",
            name: "Implementation review",
            kind: .ask,
            instructions: "Ask {{targets}} to review the current implementation and tests. Evaluate the findings, fix confirmed defects, and report both the changes and verification results."
        ),
        HandoffRecipe(
            id: "adversarial-bug-hunt",
            name: "Adversarial bug hunt",
            kind: .delegate,
            instructions: "Delegate a bounded adversarial bug hunt to {{targets}}. Require concrete file and line evidence. Ask the target to post `parley progress current` at each milestone and to return a substantial report with `parley done current --file <path>`. Wait for the tracked result, assess every finding, and fix only confirmed issues."
        ),
        HandoffRecipe(
            id: "compare-recommendations",
            name: "Compare recommendations",
            kind: .askMany,
            instructions: "Ask {{targets}} independently for recommendations on the current decision using Parley's explicit fan-out. Compare the labelled answers, preserve dissent, choose a direction, and explain why."
        ),
        HandoffRecipe(
            id: "review-and-correct",
            name: "Review and correct",
            kind: .delegate,
            instructions: "Follow the review-and-correct practice with {{targets}} as guidance, not a required sequence. Start with `parley delegate <implementer> \"<task>\"` to one of {{targets}}, asking it to post `parley progress current` at each milestone and to return its result with `parley done current` or `parley done current --file <path>` using the plain Markdown headings ## Implemented, ## Tested (each command and its claimed outcome) and ## Unable to test (the reason). When the result returns, ask a different vendor among {{targets}} to review the shared diff and name concrete file and line evidence. Send the agreed corrections back as one linked request for changes with `parley delegate <implementer> --parent <handoff-id> \"<changes>\"`, then have the reviewer verify the revised result independently. Treat every progress note, evidence section and review as an agent-declared claim and decide yourself what to accept."
        ),
    ]
}

/// Target rules derived from a recipe's identity and kind. Nothing here is
/// stored: the recipe schema stays id, name, kind and instructions.
public struct HandoffRecipeTargetRequirements: Equatable, Sendable {
    public let minimumTargets: Int
    public let minimumDistinctVendors: Int
    public var allowsMultiple: Bool { minimumTargets > 1 }

    public init(minimumTargets: Int, minimumDistinctVendors: Int) {
        self.minimumTargets = minimumTargets
        self.minimumDistinctVendors = minimumDistinctVendors
    }
}

public extension HandoffRecipe {
    static let reviewAndCorrectID = "review-and-correct"

    /// Review and correct names an implementer and a reviewer from a different
    /// vendor, so it needs at least two explicit panes spanning at least two
    /// vendors. Every other recipe keeps its kind's rule: Compare needs two
    /// panes of any vendors, Consult and Delegate need exactly one.
    var targetRequirements: HandoffRecipeTargetRequirements {
        if id == Self.reviewAndCorrectID {
            return HandoffRecipeTargetRequirements(minimumTargets: 2, minimumDistinctVendors: 2)
        }
        return HandoffRecipeTargetRequirements(minimumTargets: kind == .askMany ? 2 : 1, minimumDistinctVendors: 1)
    }
}

/// The one place that decides whether panes satisfy a recipe, used by the
/// Recipes menu, the target picker and the pure render bound alike. Callers
/// pass candidates that already exclude the lead.
public enum HandoffRecipeTargeting {
    public static func canSatisfy(_ recipe: HandoffRecipe, with candidates: [WorkbenchPane]) -> Bool {
        let requirements = recipe.targetRequirements
        return candidates.count >= requirements.minimumTargets
            && distinctVendorCount(candidates) >= requirements.minimumDistinctVendors
    }

    /// Nil when the selection satisfies the recipe; otherwise the exact reason
    /// shown to the person. Nothing is sent when a reason is returned.
    public static func rejection(for recipe: HandoffRecipe, selected: [WorkbenchPane]) -> String? {
        let requirements = recipe.targetRequirements
        if selected.count < requirements.minimumTargets {
            if requirements.minimumDistinctVendors > 1 {
                return "\(recipe.name) needs at least two explicit target panes: one to implement and a different vendor to review."
            }
            return recipe.kind == .askMany ? "Compare needs at least two selected panes." : "Choose one explicit target."
        }
        if distinctVendorCount(selected) < requirements.minimumDistinctVendors {
            let vendors = Set(selected.map(\.kind.label)).sorted().joined(separator: ", ")
            return "\(recipe.name) needs targets from at least two different vendors; the selected panes are all \(vendors)."
        }
        return nil
    }

    public static func pickerMessage(for recipe: HandoffRecipe) -> String {
        if recipe.targetRequirements.minimumDistinctVendors > 1 {
            return "Choose at least two explicit panes from different vendors: one implements and a different vendor reviews. The lead is excluded."
        }
        return recipe.kind == .askMany
            ? "Choose at least two explicit panes. They will answer independently."
            : "Choose the exact agent pane the lead should use."
    }

    public static func unavailableMessage(for recipe: HandoffRecipe) -> String {
        if recipe.targetRequirements.minimumDistinctVendors > 1 {
            return "Open at least two ready agent panes from different vendors, other than the lead."
        }
        return recipe.kind == .askMany
            ? "Open at least two ready agent panes other than the lead."
            : "Open a ready agent pane other than the lead."
    }

    private static func distinctVendorCount(_ panes: [WorkbenchPane]) -> Int {
        Set(panes.map(\.kind)).count
    }
}

public enum HandoffRecipeError: LocalizedError, Equatable {
    case invalid(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(detail), let .unreadable(detail): detail
        }
    }
}

public final class HandoffRecipeStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let recipes: [HandoffRecipe]
    }

    /// Built-in identities per document version. A persisted document must
    /// carry exactly the set for its own version; loading then backfills only
    /// the built-ins added by later versions, so local edits survive a new
    /// default while a genuinely incomplete document is still refused.
    private static let currentVersion = 2
    private static let builtInIDsByVersion: [Int: [String]] = [
        1: ["plan-review", "implementation-review", "adversarial-bug-hunt", "compare-recommendations"],
        2: HandoffRecipe.defaults.map(\.id),
    ]

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func recipes() throws -> [HandoffRecipe] {
        try lock.withLock { try loadLocked() }
    }

    public func save(_ recipe: HandoffRecipe) throws {
        try lock.withLock {
            try validate(recipe)
            var current = try loadLocked()
            guard let index = current.firstIndex(where: { $0.id == recipe.id }) else {
                throw HandoffRecipeError.invalid("Unknown recipe \(recipe.id).")
            }
            current[index] = recipe
            try writeLocked(current)
        }
    }

    public func restoreDefaults() throws {
        try lock.withLock { try writeLocked(HandoffRecipe.defaults) }
    }

    private func loadLocked() throws -> [HandoffRecipe] {
        guard fileManager.fileExists(atPath: file.path) else { return HandoffRecipe.defaults }
        do {
            try validateExistingFile()
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard let expectedIDs = Self.builtInIDsByVersion[document.version] else {
                throw HandoffRecipeError.unreadable("Unsupported handoff recipe version \(document.version).")
            }
            try document.recipes.forEach(validate)
            guard document.recipes.count == expectedIDs.count,
                  Set(document.recipes.map(\.id)) == Set(expectedIDs) else {
                throw HandoffRecipeError.unreadable("The handoff recipe set is incomplete.")
            }
            guard document.version < Self.currentVersion else { return document.recipes }
            // Additive migration: every persisted recipe, edits included, in
            // default order, plus the newer built-ins from their defaults. The
            // rewrite is best effort; the migrated set is served either way.
            let migrated = HandoffRecipe.defaults.map { definition in
                document.recipes.first(where: { $0.id == definition.id }) ?? definition
            }
            try? writeLocked(migrated)
            return migrated
        } catch let error as HandoffRecipeError {
            throw error
        } catch {
            throw HandoffRecipeError.unreadable("Handoff recipes could not be read: \(error.localizedDescription)")
        }
    }

    private func writeLocked(_ recipes: [HandoffRecipe]) throws {
        try recipes.forEach(validate)
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try validateExistingFile() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: Self.currentVersion, recipes: recipes)).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validate(_ recipe: HandoffRecipe) throws {
        guard let definition = HandoffRecipe.defaults.first(where: { $0.id == recipe.id }) else {
            throw HandoffRecipeError.invalid("Unknown recipe id.")
        }
        guard recipe.name == definition.name, recipe.kind == definition.kind else {
            throw HandoffRecipeError.invalid("Recipe names and coordination types are fixed; only instructions are editable.")
        }
        let name = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw HandoffRecipeError.invalid("Recipe names must be 1–80 characters.")
        }
        let instructions = recipe.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty, instructions.count <= RelayText.maximumCharacters else {
            throw HandoffRecipeError.invalid("Recipe instructions must be 1–\(RelayText.maximumCharacters) characters.")
        }
        guard instructions.contains("{{targets}}") else {
            throw HandoffRecipeError.invalid("Recipe instructions must include {{targets}}.")
        }
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw HandoffRecipeError.unreadable("The handoff recipe file is not an owner-only regular file.")
        }
    }
}
