import Foundation

public enum RelayText {
    public static let maximumCharacters = 100_000

    public static func clean(_ input: String) -> String {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let safeScalars = normalized.unicodeScalars.filter { scalar in
            let value = scalar.value
            if scalar == "\n" || scalar == "\t" { return true }
            if value < 0x20 || value == 0x7f || (0x80...0x9f).contains(value) { return false }
            // Box-drawing chrome is a picture of a layout, not part of an answer.
            if (0x2500...0x257f).contains(value) { return false }
            return true
        }

        let lines = String(String.UnicodeScalarView(safeScalars))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var compact: [String] = []
        for line in lines {
            if line.isEmpty, compact.last?.isEmpty == true { continue }
            compact.append(line)
        }
        while compact.first?.isEmpty == true { compact.removeFirst() }
        while compact.last?.isEmpty == true { compact.removeLast() }

        // Never truncated here. Until 22 September 2026 this kept only the
        // last `maximumCharacters`, so every route's length guard was dead and
        // a long review, answer or report lost its beginning while delivery
        // reported success. Each route now refuses over-long text instead.
        return compact.joined(separator: "\n")
    }

    /// The refusal every route returns for text over `maximumCharacters`
    /// after cleaning: what it was, its real length, and that nothing left.
    public static func tooLong(_ subject: String, count: Int, hint: String? = nil) -> String {
        "\(subject) too long: \(grouped(count)) characters after cleaning, over the \(grouped(maximumCharacters))-character limit; nothing was sent"
            + (hint.map { ". " + $0 } ?? "")
    }

    /// Digits in groups of three with a comma, whatever the locale, because
    /// agents read these messages.
    static func grouped(_ value: Int) -> String {
        var digits = Array(String(value))
        var index = digits.count - 3
        while index > 0 {
            digits.insert(",", at: index)
            index -= 3
        }
        return String(digits)
    }
}
