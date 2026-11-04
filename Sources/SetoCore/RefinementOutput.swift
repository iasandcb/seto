/// Cleans a language model's rewrite of a selected sentence.
public enum RefinementOutput {
    private static let quotePairs: [(Character, Character)] = [
        ("\"", "\""), ("'", "'"), ("`", "`"),
        ("“", "”"), ("‘", "’"), ("「", "」"), ("『", "』"), ("«", "»"),
    ]

    /// Trims surrounding whitespace and quotes from `output`, then restores
    /// the whitespace that surrounded `original`, so replacing the selection
    /// keeps the spacing next to it. Quotes the original itself starts with
    /// are kept.
    public static func clean(_ output: String, original: String) -> String {
        let core = trimmed(Substring(original))
        var text = trimmed(Substring(output))
        while text.count >= 2, let first = text.first, let last = text.last,
              quotePairs.contains(where: { $0.0 == first && $0.1 == last }),
              core.first != first {
            text = trimmed(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { return "" }
        let leading = original.prefix(while: \.isWhitespace)
        let trailing = original.reversed().prefix(while: \.isWhitespace)
        return String(leading) + text + String(trailing.reversed())
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var text = text.drop(while: \.isWhitespace)
        while text.last?.isWhitespace == true { text = text.dropLast() }
        return text
    }
}
