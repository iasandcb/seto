import Foundation

/// A candidate owns only the trailing word at the captured caret position.
public struct WordSuggestionContext: Equatable, Sendable {
    public let before: String
    public let after: String?
    public let word: String
    /// The caret is after whitespace, so `word` is empty and a candidate is inserted.
    public let predictsNextWord: Bool

    public init?(before: String?, after: String?) {
        guard let before, let last = before.last, Self.isWordCharacter(last),
              after?.first.map(Self.isWordCharacter) != true else { return nil }
        let word = String(before.reversed().prefix(while: Self.isWordCharacter).reversed())
        guard word.count <= 32, !word.isEmpty else { return nil }
        // Do not suggest the alphabetic tail of identifiers, URLs, or emails.
        if let boundary = before.dropLast(word.count).last,
           boundary.isNumber || "_/@.:\\-".contains(boundary) { return nil }
        self.before = before
        self.after = after
        self.word = word
        self.predictsNextWord = false
    }

    /// Caret after whitespace. Used to offer a frequent next word.
    public static func nextWord(before: String?, after: String?) -> WordSuggestionContext? {
        guard let before, let last = before.last, last.isWhitespace else { return nil }
        if let first = after?.first, Self.isWordCharacter(first) { return nil }
        return WordSuggestionContext(before: before, after: after, word: "", predictsNextWord: true)
    }

    public static func forComposition(before: String?, after: String?, allowNextWord: Bool) -> WordSuggestionContext? {
        if let current = WordSuggestionContext(before: before, after: after) { return current }
        guard allowNextWord else { return nil }
        return nextWord(before: before, after: after)
    }

    private init(before: String, after: String?, word: String, predictsNextWord: Bool) {
        self.before = before
        self.after = after
        self.word = word
        self.predictsNextWord = predictsNextWord
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter
    }
}

/// Small offline candidate engine. The extension retains only the frequent
/// Korean words and uses bounded binary searches in its mapped English list.
public final class WordSuggestions: Sendable {
    private let lexicon: Lexicon
    private let korean: [(word: String, keys: String)]

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
        korean = lexicon.koreanWords().compactMap { word in
            TypoCorrector.keystrokes(for: word, layout: .dubeol).map { (word, $0) }
        }
    }

    public func candidates(for word: String, limit: Int = 3) -> [String] {
        guard !word.isEmpty, word.count <= 32, limit > 0 else { return [] }
        var matches: [String: Int] = [:]
        if let keys = TypoCorrector.keystrokes(for: word, layout: .dubeol) {
            for entry in korean where entry.word != word {
                if entry.keys.hasPrefix(keys) { matches[entry.word] = 0 }
                else if keys.count >= 4, Self.isOneEdit(keys, entry.keys) { matches[entry.word] = 1 }
            }
        } else {
            guard word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [] }
            let lower = word.lowercased()
            for entry in lexicon.englishCompletions(lower) where entry != lower { matches[entry] = 0 }
            if lower.count >= 3, !lexicon.isEnglishWord(lower) {
                let letters = Array(lower)
                func add(_ candidate: String) {
                    if candidate != lower, lexicon.isEnglishWord(candidate), matches[candidate] == nil {
                        matches[candidate] = 1
                    }
                }
                for index in letters.indices {
                    var removed = letters
                    removed.remove(at: index)
                    add(String(removed))
                    for letter in "abcdefghijklmnopqrstuvwxyz" {
                        var changed = letters
                        changed[index] = letter
                        add(String(changed))
                    }
                    if index + 1 < letters.count {
                        var swapped = letters
                        swapped.swapAt(index, index + 1)
                        add(String(swapped))
                    }
                }
                for index in 0...letters.count {
                    for letter in "abcdefghijklmnopqrstuvwxyz" {
                        var inserted = letters
                        inserted.insert(letter, at: index)
                        add(String(inserted))
                    }
                }
            }
            return ranked(matches, limit: limit).map { candidate in
                if word.allSatisfy(\.isUppercase) { return candidate.uppercased() }
                if word.first?.isUppercase == true { return candidate.prefix(1).uppercased() + candidate.dropFirst() }
                return candidate
            }
        }
        return ranked(matches, limit: limit)
    }

    /// Learned prefix matches stay ahead of dictionary completions and typo fixes.
    public func candidates(for word: String, promoting personal: [String], limit: Int = 3) -> [String] {
        let dictionary = candidates(for: word, limit: limit)
        guard !personal.isEmpty else { return dictionary }
        var seen = Set<String>()
        var result: [String] = []
        for candidate in personal.map({ Self.matchingCase($0, like: word) }) + dictionary {
            let identity = candidate.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(identity).inserted else { continue }
            result.append(candidate)
            if result.count == limit { break }
        }
        return result
    }

    private static func matchingCase(_ candidate: String, like typed: String) -> String {
        guard candidate.allSatisfy({ $0.isASCII && $0.isLetter }) else { return candidate }
        let base = candidate.lowercased()
        if typed.allSatisfy(\.isUppercase) { return base.uppercased() }
        if typed.first?.isUppercase == true { return base.prefix(1).uppercased() + base.dropFirst() }
        return base
    }

    private func ranked(_ matches: [String: Int], limit: Int) -> [String] {
        Array(matches.keys.sorted {
            if matches[$0] != matches[$1] { return matches[$0]! < matches[$1]! }
            if $0.count != $1.count { return $0.count < $1.count }
            return $0 < $1
        }.prefix(limit))
    }

    private static func isOneEdit(_ left: String, _ right: String) -> Bool {
        let a = Array(left), b = Array(right)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) == 1
    }
}
