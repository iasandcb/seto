/// A grapheme-based edit for clients, such as iOS keyboard extensions, which
/// can insert text and delete backward but cannot set a marked range.
public struct KeyboardReplacement: Equatable, Sendable {
    public let removed: String
    public let inserted: String
    public var deleteCount: Int { removed.count }

    public static func between(_ before: String, _ after: String) -> Self {
        let shared = zip(before, after).prefix { $0 == $1 }.count
        return Self(removed: String(before.dropFirst(shared)), inserted: String(after.dropFirst(shared)))
    }
}
