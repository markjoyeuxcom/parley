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
            // tmux borders are a picture of the layout, not part of an answer.
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

        let cleaned = compact.joined(separator: "\n")
        if cleaned.count <= maximumCharacters { return cleaned }
        return String(cleaned.suffix(maximumCharacters))
    }
}
