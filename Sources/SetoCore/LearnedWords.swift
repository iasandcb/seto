import Foundation

/// On-device counts and recency for words the user has committed.
/// Password and secure fields must pass `secure: true` so nothing is stored.
public final class LearnedWords: @unchecked Sendable {
    public static let defaultCapacity = 400
    public static let storageKey = "learnedWords.v1"
    /// Info.plist string. When absent, the keyboard extension uses its own defaults.
    public static let appGroupInfoKey = "SebeolAppGroup"

    private struct Record: Codable, Equatable {
        var count: Int
        var lastUsed: Date
        var display: String
        var keys: String?
    }

    private struct State: Codable {
        var records: [String: Record]
        var followers: [String: [String: Int]]
    }

    private static let followerCap = 8
    private static let bigramMinimum = 2
    private static let fallbackMinimum = 3
    private static let staleInterval: TimeInterval = 30 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let capacity: Int
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var followers: [String: [String: Int]] = [:]

    public init(defaults: UserDefaults = .standard, capacity: Int = LearnedWords.defaultCapacity) {
        self.defaults = defaults
        self.capacity = max(1, capacity)
        load()
        lock.lock()
        if prune(now: Date()) { save() }
        lock.unlock()
    }

    /// App-group suite when the host configured one, otherwise this process's defaults.
    public static func resolvedDefaults(bundle: Bundle = .main) -> UserDefaults {
        guard let identifier = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !identifier.isEmpty,
              let suite = UserDefaults(suiteName: identifier) else { return .standard }
        return suite
    }

    /// Text before the caret after deleting `removing` and inserting `inserting`.
    public static func applyingEdit(to before: String?, removing: String, inserting: String) -> String? {
        guard var text = before else { return nil }
        if !removing.isEmpty {
            guard text.hasSuffix(removing) else { return nil }
            text.removeLast(removing.count)
        }
        text.append(contentsOf: inserting)
        return text
    }

    /// The word before `current` in `text`, ignoring a trailing boundary.
    public static func precedingWord(in text: String, current: String) -> String? {
        var head = text
        if !current.isEmpty, head.hasSuffix(current) {
            head.removeLast(current.count)
        }
        return lastWord(in: head)
    }

    public func learn(_ word: String, after previous: String? = nil, secure: Bool = false, at date: Date = Date()) {
        guard !secure else { return }
        guard let key = Self.normalize(word) else { return }
        let display = word.precomposedStringWithCanonicalMapping
        let keys: String?
        if display.allSatisfy({ $0.isASCII && $0.isLetter }) {
            keys = nil
        } else if let strokes = TypoCorrector.keystrokes(for: display, layout: .dubeol) {
            keys = strokes
        } else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        var record = records[key] ?? Record(count: 0, lastUsed: date, display: display, keys: keys)
        record.count += 1
        record.lastUsed = date
        record.display = display
        record.keys = keys
        records[key] = record
        if let previous, let previousKey = Self.normalize(previous), records[previousKey] != nil {
            var map = followers[previousKey] ?? [:]
            map[key, default: 0] += 1
            while map.count > Self.followerCap {
                guard let victim = map.min(by: { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value < rhs.value }
                    return lhs.key < rhs.key
                })?.key else { break }
                map.removeValue(forKey: victim)
            }
            followers[previousKey] = map
        }
        _ = prune(now: date)
        save()
    }

    /// Learns words closed by a newly inserted boundary. Secure fields are ignored.
    public func observe(from old: String?, to new: String?, secure: Bool = false, at date: Date = Date()) {
        guard !secure, let old, let new else { return }
        for item in Self.committedWords(from: old, to: new) {
            learn(item.word, after: item.previous, secure: false, at: date)
        }
    }

    /// Prefix matches, highest frequency-plus-recency first. One character or syllable is enough.
    public func prefixMatches(for typed: String, limit: Int = 3, at now: Date = Date()) -> [String] {
        let typed = typed.precomposedStringWithCanonicalMapping
        guard !typed.isEmpty, typed.count <= 32, limit > 0 else { return [] }
        let typedKeys = TypoCorrector.keystrokes(for: typed, layout: .dubeol)
        let typedLower = typed.lowercased()
        let english = typed.allSatisfy { $0.isASCII && $0.isLetter }
        lock.lock()
        let snapshot = records
        lock.unlock()
        var ranked: [(display: String, score: Double, length: Int)] = []
        for (key, record) in snapshot {
            if key == typedLower || record.display == typed { continue }
            let matched: Bool
            if let typedKeys, let keys = record.keys {
                matched = keys.hasPrefix(typedKeys) && keys != typedKeys
            } else if english, record.keys == nil {
                matched = key.hasPrefix(typedLower)
            } else {
                matched = false
            }
            guard matched else { continue }
            ranked.append((
                record.display,
                Self.rankScore(count: record.count, lastUsed: record.lastUsed, now: now),
                record.display.count
            ))
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return lhs.display < rhs.display
        }
        var seen = Set<String>()
        var result: [String] = []
        for item in ranked {
            guard seen.insert(item.display.lowercased()).inserted else { continue }
            result.append(item.display)
            if result.count == limit { break }
        }
        return result
    }

    /// A frequent follower of the word before the caret, or a globally frequent word.
    public func nextWords(after textBeforeCaret: String, limit: Int = 3, at now: Date = Date()) -> [String] {
        guard limit > 0 else { return [] }
        let previousKey = Self.lastWord(in: textBeforeCaret).flatMap(Self.normalize)
        lock.lock()
        let snapshot = records
        let followerMap = previousKey.flatMap { followers[$0] } ?? [:]
        lock.unlock()
        var picked: [(display: String, score: Double)] = []
        let frequentFollowers = followerMap.filter { $0.value >= Self.bigramMinimum }
        if !frequentFollowers.isEmpty {
            for (key, count) in frequentFollowers {
                guard let record = snapshot[key] else { continue }
                picked.append((record.display, Self.rankScore(count: count, lastUsed: record.lastUsed, now: now)))
            }
        } else {
            for (_, record) in snapshot where record.count >= Self.fallbackMinimum {
                picked.append((record.display, Self.rankScore(count: record.count, lastUsed: record.lastUsed, now: now)))
            }
        }
        picked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.display < rhs.display
        }
        var seen = Set<String>()
        var result: [String] = []
        for item in picked {
            guard seen.insert(item.display.lowercased()).inserted else { continue }
            result.append(item.display)
            if result.count == limit { break }
        }
        return result
    }

    static func rankScore(count: Int, lastUsed: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(lastUsed))
        let recency = exp(-age / (3 * 24 * 3600))
        return Double(count) + recency
    }

    static func committedWords(from old: String, to new: String) -> [(word: String, previous: String?)] {
        guard new.count > old.count else { return [] }
        let shared = commonPrefixCount(old, new)
        let boundaryStart = new.index(new.startIndex, offsetBy: shared)
        var result: [(word: String, previous: String?)] = []
        var previous: String?
        var wordStart: String.Index?
        var index = new.startIndex
        while index < new.endIndex {
            if new[index].isLetter {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                let word = String(new[start..<index])
                if index >= boundaryStart {
                    result.append((word, previous))
                }
                previous = word
                wordStart = nil
            }
            index = new.index(after: index)
        }
        return result
    }

    private static func lastWord(in text: String) -> String? {
        let trimmed = trimmingNonLetters(fromEnd: text)
        guard let word = trimmed.split(whereSeparator: { !$0.isLetter }).last else { return nil }
        let value = String(word)
        return normalize(value) == nil ? nil : value
    }

    private static func trimmingNonLetters(fromEnd text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            if text[previous].isLetter { break }
            end = previous
        }
        return String(text[..<end])
    }

    private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
            count += 1
            left = lhs.index(after: left)
            right = rhs.index(after: right)
        }
        return count
    }

    /// English words are at least two letters. Korean entries are complete syllables.
    static func normalize(_ word: String) -> String? {
        let text = word.precomposedStringWithCanonicalMapping
        guard (1...32).contains(text.count) else { return nil }
        if text.allSatisfy({ $0.isASCII && $0.isLetter }) {
            guard text.count >= 2 else { return nil }
            return text.lowercased()
        }
        guard text.unicodeScalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) }) else { return nil }
        return text
    }

    private func prune(now: Date) -> Bool {
        let beforeRecords = records
        let beforeFollowers = followers
        let horizon = now.addingTimeInterval(-Self.staleInterval)
        for (key, record) in records where record.count <= 1 && record.lastUsed < horizon {
            records.removeValue(forKey: key)
        }
        if records.count > capacity {
            let ranked = records.sorted { lhs, rhs in
                let left = Self.rankScore(count: lhs.value.count, lastUsed: lhs.value.lastUsed, now: now)
                let right = Self.rankScore(count: rhs.value.count, lastUsed: rhs.value.lastUsed, now: now)
                if left != right { return left < right }
                return lhs.key < rhs.key
            }
            for item in ranked.prefix(records.count - capacity) {
                records.removeValue(forKey: item.key)
            }
        }
        var cleaned: [String: [String: Int]] = [:]
        for (key, map) in followers where records[key] != nil {
            let kept = map.filter { records[$0.key] != nil }
            if !kept.isEmpty { cleaned[key] = kept }
        }
        followers = cleaned
        return records != beforeRecords || followers != beforeFollowers
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(State.self, from: data) else { return }
        records = state.records
        followers = state.followers
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(State(records: records, followers: followers)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
