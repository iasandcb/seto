import Foundation

/// Particles (including colloquial 두 for 도) and productive 하다 forms
/// attached to a known dictionary word.
enum KoreanEndings {
    static let longestFirst = [
        "에서", "으로", "하고", "하는", "하기", "하다", "하면", "해서", "하자",
        "는", "은", "이", "가", "를", "을", "에", "로",
        "와", "과", "도", "두", "만", "의", "했", "해",
    ]
    static let set = Set(longestFirst)

    static func split(_ word: String) -> (stem: String, ending: String)? {
        let word = word.precomposedStringWithCanonicalMapping
        for ending in longestFirst where word.count > ending.count && word.hasSuffix(ending) {
            let stem = String(word.dropLast(ending.count))
            if !stem.isEmpty {
                return (stem, ending)
            }
        }
        return nil
    }
}

/// Verb and adjective endings. The validity list holds mostly dictionary
/// forms, so 오고, 와서, 주면, 먹었다 are missing from it. A word made of an
/// attested stem plus one of these endings is a correctly formed word, not a typo.
enum KoreanVerbEndings {
    static let longestFirst = [
        "습니다", "었는데", "았는데", "니까", "는데", "면서", "지만", "도록", "려고", "어서", "아서",
        "어요", "아요", "세요", "는지", "었다", "았다", "었어", "았어", "겠다",
        "고", "기", "면", "서", "지", "게", "는", "며", "니", "다", "요", "자", "네", "던", "도", "나", "냐", "죠", "어", "아",
    ]

    /// True when `word` is stem + ending and the stem is a known word, is seen
    /// with another verb ending, or ends in the past marker ㅆ (왔, 먹었).
    static func isInflected(_ word: String, isKnown: (String) -> Bool) -> Bool {
        for ending in longestFirst where word.count > ending.count && word.hasSuffix(ending) {
            let stem = String(word.dropLast(ending.count))
            guard stem.count <= 3 else { continue }
            if isKnown(stem) || endsInPastMarker(stem) { return true }
            if longestFirst.contains(where: { $0 != ending && isKnown(stem + $0) }) { return true }
        }
        return false
    }

    private static func endsInPastMarker(_ stem: String) -> Bool {
        guard let scalar = stem.unicodeScalars.last, (0xAC00...0xD7A3).contains(scalar.value) else { return false }
        return (scalar.value - 0xAC00) % 28 == 20
    }
}

/// One confident dictionary replacement for a finished word, or nil.
/// Costs are millicosts so the margin does not depend on binary fractions.
/// A short word allows a single cheap edit. A long one allows two.
public enum TypoCorrector {
    public static func correction(
        composed: String,
        keys: [KeyAtom],
        language: Language,
        lexicon: Lexicon,
        memory: (any TypoMemory)?
    ) -> String? {
        let composed = composed.precomposedStringWithCanonicalMapping
        guard !composed.isEmpty else { return nil }
        switch language {
        case .korean:
            return korean(composed: composed, keys: keys, lexicon: lexicon, memory: memory)
        case .english:
            return english(composed: composed, lexicon: lexicon, memory: memory)
        }
    }

    /// A valid or plausible Hangul word is left alone. Otherwise replace it
    /// only when one frequent word (or that word plus the typed ending) uses
    /// the same keys with exactly one of them different. An extra or missing
    /// jamo stays, so 갔어 is not rewritten as 갔었.
    private static func korean(
        composed: String,
        keys: [KeyAtom],
        lexicon: Lexicon,
        memory: (any TypoMemory)?
    ) -> String? {
        if isAlreadyKorean(composed, lexicon: lexicon) { return nil }
        if let logged = loggedKorean(composed, memory: memory, lexicon: lexicon) {
            return logged
        }
        guard composed.count >= 2, composed.allSatisfy(isModernSyllable) else { return nil }
        let typed = String(keys.map(\.english))
        guard typed.count >= 2 else { return nil }
        var winner: String?
        for candidate in frequentCandidates(lexicon, layout: keys.first?.layout ?? .sebeol390) {
            guard isOneKeySubstitution(typed, candidate.keys) else { continue }
            if let winner, winner != candidate.word { return nil }
            winner = candidate.word
        }
        guard let winner, winner != composed else { return nil }
        return winner
    }

    private static func english(composed: String, lexicon: Lexicon, memory: (any TypoMemory)?) -> String? {
        guard composed.allSatisfy(\.isLetter), composed.count >= 2 else { return nil }
        if composed.allSatisfy(\.isUppercase) { return nil }
        if composed.dropFirst().contains(where: \.isUppercase) { return nil }
        let lower = composed.lowercased()
        if lexicon.isEnglishWord(lower) || lexicon.isAbbreviation(composed) || lexicon.isCodeToken(composed) {
            return nil
        }
        if let logged = memory?.uniqueFinal(for: composed) ?? memory?.uniqueFinal(for: lower) {
            let loggedLower = logged.lowercased()
            if loggedLower != lower, logged.allSatisfy(\.isLetter), lexicon.isEnglishWord(loggedLower) {
                return matchingCase(loggedLower, like: composed)
            }
        }
        guard lower.count >= 4 else { return nil }
        let source = Array(lower)
        let limit = source.count >= 8 ? longLimit : shortLimit
        let band = max(1, source.count - 1)...(source.count + 1)
        var found: [String: Int] = [:]
        for candidate in lexicon.englishWords(length: band) {
            guard candidate != lower else { continue }
            let cost = editCost(source, Array(candidate), limit: limit, substitute: letterCost, allowTranspose: true)
            guard (1...limit).contains(cost) else { continue }
            if let old = found[candidate], old <= cost { continue }
            found[candidate] = cost
        }
        guard let winner = uniqueWinner(found) else { return nil }
        let cased = matchingCase(winner, like: composed)
        return cased == composed ? nil : cased
    }

    private static func loggedKorean(_ composed: String, memory: (any TypoMemory)?, lexicon: Lexicon) -> String? {
        guard let logged = memory?.uniqueFinal(for: composed), logged != composed else { return nil }
        guard isHangulReading(logged), isAlreadyKorean(logged, lexicon: lexicon) else { return nil }
        return logged
    }

    /// Frequent words, the large validity list, a stem plus one ending, or an ending alone.
    private static func isAlreadyKorean(_ word: String, lexicon: Lexicon) -> Bool {
        let word = word.precomposedStringWithCanonicalMapping
        if KoreanEndings.set.contains(word) { return true }
        if lexicon.isKoreanWord(word) || lexicon.isValidKorean(word) { return true }
        if let (stem, _) = KoreanEndings.split(word) {
            if lexicon.isKoreanWord(stem) || lexicon.isValidKorean(stem) { return true }
        }
        return KoreanVerbEndings.isInflected(word) { lexicon.isKoreanWord($0) || lexicon.isValidKorean($0) }
    }

    private static func isModernSyllable(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return (0xAC00...0xD7A3).contains(scalar.value)
    }

    private static func isHangulReading(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return word.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (0xAC00...0xD7A3).contains(value) || (0x3131...0x318E).contains(value)
        }
    }

    private static func matchingCase(_ replacement: String, like source: String) -> String {
        guard let first = source.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    private static func uniqueWinner(_ found: [String: Int]) -> String? {
        let ranked = found.values.sorted()
        guard let bestCost = ranked.first else { return nil }
        let winners = found.compactMap { $0.value == bestCost ? $0.key : nil }
        guard winners.count == 1 else { return nil }
        let second = ranked.dropFirst().first ?? Int.max
        guard second > bestCost + margin else { return nil }
        return winners[0]
    }

    /// One adjacent-key substitution on an English word of at least four letters.
    /// An inserted letter (850) loses to that substitution, so hellp becomes hello.
    private static let shortLimit = 700
    private static let longLimit = 1500
    private static let margin = 250
    private static let insertCost = 850
    private static let transposeCost = 700
    private static let genericCost = 2000

    private static func letterCost(_ left: Character, _ right: Character) -> Int {
        if left == right { return 0 }
        return orthogonal(left, right) ? 550 : genericCost
    }

    private static func editCost<T: Equatable>(
        _ left: [T],
        _ right: [T],
        limit: Int,
        substitute: (T, T) -> Int,
        allowTranspose: Bool
    ) -> Int {
        if left == right { return 0 }
        let lengthGap = abs(left.count - right.count)
        if lengthGap * insertCost > limit { return limit + 1 }
        let columns = right.count + 1
        var previousPrevious = [Int]()
        var previous = Array(0..<columns).map { $0 * insertCost }
        var current = Array(repeating: 0, count: columns)
        for row in 1...left.count {
            current[0] = row * insertCost
            var rowMin = current[0]
            for column in 1...right.count {
                var best = min(
                    previous[column - 1] + substitute(left[row - 1], right[column - 1]),
                    previous[column] + insertCost,
                    current[column - 1] + insertCost
                )
                if allowTranspose, row > 1, column > 1,
                   left[row - 1] == right[column - 2], left[row - 2] == right[column - 1] {
                    best = min(best, previousPrevious[column - 2] + transposeCost)
                }
                current[column] = best
                rowMin = min(rowMin, best)
            }
            if rowMin > limit { return limit + 1 }
            previousPrevious = previous
            previous = current
        }
        return previous[right.count]
    }

    private struct FrequentCandidate {
        var word: String
        var keys: String
    }

    private final class CandidateCache: @unchecked Sendable {
        let lock = NSLock()
        var stored: [ObjectIdentifier: [KeyboardLayout: (count: Int, rows: [FrequentCandidate])]] = [:]
    }

    private static let candidateCache = CandidateCache()

    /// Frequent words, and each of those words with one grammatical ending.
    /// The ending's keys are part of the same one-key comparison.
    private static func frequentCandidates(_ lexicon: Lexicon, layout: KeyboardLayout) -> [FrequentCandidate] {
        candidateCache.lock.lock()
        defer { candidateCache.lock.unlock() }
        let key = ObjectIdentifier(lexicon)
        if let hit = candidateCache.stored[key]?[layout], hit.count == lexicon.koreanWordCount {
            return hit.rows
        }
        var rows: [FrequentCandidate] = []
        var seen: Set<String> = []
        func add(_ word: String, _ keys: String) {
            let identity = word + "\u{0}" + keys
            guard seen.insert(identity).inserted else { return }
            rows.append(FrequentCandidate(word: word, keys: keys))
        }
        for word in lexicon.koreanWords() {
            guard let keys = keystrokes(for: word, layout: layout) else { continue }
            add(word, keys)
            for ending in KoreanEndings.longestFirst {
                guard let tail = keystrokes(for: ending, layout: layout) else { continue }
                add(word + ending, keys + tail)
            }
        }
        candidateCache.stored[key, default: [:]][layout] = (lexicon.koreanWordCount, rows)
        return rows
    }

    /// Same number of keys, one position different. Inserting or deleting a key
    /// is not a correction: 갔어 and 갔었 differ by the final ㅆ.
    private static func isOneKeySubstitution(_ typed: String, _ canonical: String) -> Bool {
        if typed.count != canonical.count || typed == canonical { return false }
        let left = Array(typed)
        let right = Array(canonical)
        var mismatches = 0
        for index in left.indices where left[index] != right[index] {
            mismatches += 1
            if mismatches > 1 { return false }
        }
        return mismatches == 1
    }

    static func keystrokes(for word: String, layout: KeyboardLayout) -> String? {
        var result = ""
        for character in word.precomposedStringWithCanonicalMapping {
            guard let part = keystrokes(for: character, layout: layout) else { return nil }
            result += part
        }
        return result.isEmpty ? nil : result
    }

    private static func keystrokes(for syllable: Character, layout: KeyboardLayout) -> String? {
        guard let scalar = syllable.unicodeScalars.first, syllable.unicodeScalars.count == 1 else { return nil }
        let value = scalar.value
        guard (0xAC00...0xD7A3).contains(value) else {
            // Suggestions also receive the unfinished compatibility jamo at
            // the end of the currently displayed Korean word.
            guard let jamo = canonicalKeys[layout]?.keys.first(where: { $0.compat == syllable }) else { return nil }
            return keySequence(jamo.kind, jamo.scalar, layout: layout)
        }
        let code = value - 0xAC00
        let cho = 0x1100 + code / 588
        let jung = 0x1161 + (code % 588) / 28
        let jong = code % 28
        guard let choKeys = keySequence(.choseong, cho, layout: layout), let jungKeys = keySequence(.jungseong, jung, layout: layout) else { return nil }
        var text = choKeys + jungKeys
        if jong != 0 {
            guard let jongKeys = keySequence(.jongseong, 0x11A8 + jong - 1, layout: layout) else { return nil }
            text += jongKeys
        }
        return text
    }

    /// Prefer a direct key for the selected layout, then try two merging keys.
    /// A lowercase letter wins over a digit that produces the same jamo.
    private static func keySequence(_ kind: JamoKind, _ scalar: UInt32, layout: KeyboardLayout) -> String? {
        let canonicalKey = canonicalKeys[layout]!
        let target = Jamo(scalar: scalar, kind: kind)
        if let key = canonicalKey[target] { return String(key) }
        for (first, firstKey) in canonicalKey where first.kind == kind {
            for (second, secondKey) in canonicalKey where second.kind == kind {
                if Hangul.merge(first, second) == target {
                    return String(firstKey) + String(secondKey)
                }
            }
        }
        return nil
    }

    private static let canonicalKeys: [KeyboardLayout: [Jamo: Character]] = {
        var layouts: [KeyboardLayout: [Jamo: Character]] = [:]
        for layout in KeyboardLayout.allCases {
            layouts[layout] = canonicalKey(for: layout)
        }
        return layouts
    }()

    private static func canonicalKey(for layout: KeyboardLayout) -> [Jamo: Character] {
        var map: [Jamo: Character] = [:]
        for character in Array("abcdefghijklmnopqrstuvwxyz") {
            if case .jamo(let jamo) = layout.atom(for: character).korean {
                map[jamo] = character
            }
        }
        let rest = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`-=[]\\;',./~!@#$%^&*()_+{}|:\"<>?")
        for character in rest {
            if case .jamo(let jamo) = layout.atom(for: character).korean, map[jamo] == nil {
                map[jamo] = character
            }
        }
        if layout == .dubeol {
            for (jamo, key) in Array(map) where jamo.kind == .choseong {
                if let final = LayoutDubeol.final(forInitial: jamo) { map[final] = key }
            }
        }
        return map
    }

    private static let keyPosition: [Character: (Int, Int)] = {
        let rows = ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"]
        var map: [Character: (Int, Int)] = [:]
        for (row, keys) in rows.enumerated() {
            for (column, character) in keys.enumerated() {
                map[character] = (row, column)
            }
        }
        return map
    }()

    /// Shares an edge. A diagonal pair is not a one-key slip.
    private static func orthogonal(_ left: Character, _ right: Character) -> Bool {
        guard let a = keyPosition[left], let b = keyPosition[right] else { return false }
        return abs(a.0 - b.0) + abs(a.1 - b.1) == 1
    }
}
