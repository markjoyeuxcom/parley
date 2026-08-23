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
        let minimum = kind == .askMany ? 2 : 1
        guard cleanedTargets.count >= minimum else {
            throw HandoffRecipeError.invalid(
                kind == .askMany ? "Compare needs at least two explicit targets." : "Choose one explicit target."
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
            instructions: "Delegate a bounded adversarial bug hunt to {{targets}}. Require concrete file and line evidence, wait for the tracked result, assess every finding, and fix only confirmed issues."
        ),
        HandoffRecipe(
            id: "compare-recommendations",
            name: "Compare recommendations",
            kind: .askMany,
            instructions: "Ask {{targets}} independently for recommendations on the current decision using Parley's explicit fan-out. Compare the labelled answers, preserve dissent, choose a direction, and explain why."
        ),
    ]
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
            guard document.version == 1 else {
                throw HandoffRecipeError.unreadable("Unsupported handoff recipe version \(document.version).")
            }
            try document.recipes.forEach(validate)
            guard Set(document.recipes.map(\.id)) == Set(HandoffRecipe.defaults.map(\.id)) else {
                throw HandoffRecipeError.unreadable("The handoff recipe set is incomplete.")
            }
            return document.recipes
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
        try encoder.encode(Document(version: 1, recipes: recipes)).write(to: file, options: .atomic)
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
