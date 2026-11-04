/// Moves through the cached suggestions of the refinement panel.
///
/// Tab walks forward through the cache. Only on the last cached suggestion,
/// and only while more can be generated, does it ask for a new one; otherwise
/// it wraps to the first. ⇧⇥ walks backward and wraps to the last, never
/// generating.
public enum SuggestionCursor {
    public enum Step: Equatable, Sendable {
        /// Show the cached suggestion at this index.
        case show(Int)
        /// Ask for a new suggestion, to be appended after the last one.
        case generate
    }

    /// Where Tab goes from `index` with `count` cached suggestions.
    /// `canGenerate` is false once generation has stopped (unavailable,
    /// failed, or returned a duplicate).
    public static func next(index: Int, count: Int, maximum: Int, canGenerate: Bool) -> Step {
        guard count > 0 else { return canGenerate && maximum > 0 ? .generate : .show(0) }
        let current = min(max(index, 0), count - 1)
        if current < count - 1 { return .show(current + 1) }
        if canGenerate, count < maximum { return .generate }
        return .show(0)
    }

    /// Where ⇧⇥ goes from `index` with `count` cached suggestions.
    public static func previous(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let current = min(max(index, 0), count - 1)
        return current == 0 ? count - 1 : current - 1
    }
}
