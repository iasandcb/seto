/// A small LCS diff for showing a refinement next to its original.
public enum TextDiff {
    public enum Segment: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// Strings shorter than this (in Characters) are compared per Character.
    static let characterLevelLimit = 200
    /// Fewer word/space tokens than this also compares per Character, which
    /// suits Korean edits inside a single eojeol.
    static let minimumTokens = 8
    /// The LCS table is n×m; beyond this the whole text counts as replaced.
    static let maximumCells = 250_000

    public static func diff(_ old: String, _ new: String) -> [Segment] {
        if old == new { return old.isEmpty ? [] : [.same(old)] }

        // Common ends need no table and keep the table small.
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        let short = max(oldChars.count, newChars.count) < characterLevelLimit
        let few = max(tokens(old).count, tokens(new).count) < minimumTokens
        let byCharacter = short || few
        if !byCharacter {
            // Whole words change in a token diff; keep shared word parts in it.
            while prefix > 0, !oldChars[prefix - 1].isWhitespace { prefix -= 1 }
            while suffix > 0, !oldChars[oldChars.count - suffix].isWhitespace { suffix -= 1 }
        }
        let oldMiddle = String(oldChars[prefix..<(oldChars.count - suffix)])
        let newMiddle = String(newChars[prefix..<(newChars.count - suffix)])

        var segments: [Segment] = []
        if prefix > 0 { segments.append(.same(String(oldChars[..<prefix]))) }
        segments += diffMiddle(oldMiddle, newMiddle, byCharacter: byCharacter)
        if suffix > 0 { segments.append(.same(String(oldChars[(oldChars.count - suffix)...]))) }
        return merged(segments)
    }

    private static func diffMiddle(_ old: String, _ new: String, byCharacter: Bool) -> [Segment] {
        if old.isEmpty { return new.isEmpty ? [] : [.added(new)] }
        if new.isEmpty { return [.removed(old)] }
        let units = byCharacter
            ? (old.map(String.init), new.map(String.init))
            : (tokens(old), tokens(new))
        return lcs(units.0, units.1) ?? [.removed(old), .added(new)]
    }

    /// Runs of non-whitespace and runs of whitespace, alternating.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in text {
            let isSpace = character.isWhitespace
            if currentIsSpace != nil, currentIsSpace != isSpace {
                result.append(current)
                current = ""
            }
            current.append(character)
            currentIsSpace = isSpace
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// nil when the table would exceed `maximumCells`.
    private static func lcs(_ a: [String], _ b: [String]) -> [Segment]? {
        let n = a.count, m = b.count
        guard (n + 1).multipliedReportingOverflow(by: m + 1).partialValue <= maximumCells else { return nil }
        let width = m + 1
        // table[i][j] = LCS length of a[i...] and b[j...]
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var segments: [Segment] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                segments.append(.same(a[i])); i += 1; j += 1
            } else if j == m || (i < n && table[(i + 1) * width + j] >= table[i * width + j + 1]) {
                segments.append(.removed(a[i])); i += 1
            } else {
                segments.append(.added(b[j])); j += 1
            }
        }
        return segments
    }

    /// Joins neighbours of one kind, and puts each change's removal before
    /// its addition so the original and the suggestion each read in order.
    private static func merged(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        var removed = "", added = ""
        func flush() {
            if !removed.isEmpty { result.append(.removed(removed)) }
            if !added.isEmpty { result.append(.added(added)) }
            removed = ""; added = ""
        }
        for segment in segments {
            switch segment {
            case .removed(let text): removed += text
            case .added(let text): added += text
            case .same(let text):
                flush()
                if case .same(let previous)? = result.last {
                    result[result.count - 1] = .same(previous + text)
                } else if !text.isEmpty {
                    result.append(.same(text))
                }
            }
        }
        flush()
        return result
    }
}

public extension [TextDiff.Segment] {
    /// The original text: unchanged and removed parts.
    var oldText: String {
        map { if case .added = $0 { return "" }; return $0.text }.joined()
    }

    /// The new text: unchanged and added parts.
    var newText: String {
        map { if case .removed = $0 { return "" }; return $0.text }.joined()
    }
}

public extension TextDiff.Segment {
    var text: String {
        switch self {
        case .same(let text), .removed(let text), .added(let text): text
        }
    }
}
