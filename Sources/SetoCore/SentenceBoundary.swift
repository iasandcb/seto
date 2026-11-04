/// Finds where the sentence that ends at the caret probably starts.
///
/// Offsets are UTF-16, matching NSRange in IMK and Accessibility. Every
/// boundary is a BMP character, so scanning code units never splits a
/// surrogate pair.
public enum SentenceBoundary {
    /// Just after the last `.`, `?`, `!`, `。` or line break before `caret`,
    /// with leading whitespace skipped. Never past `caret`; returns `caret`
    /// when the caret directly follows a boundary.
    public static func start(in text: String, before caret: Int) -> Int {
        let units = Array(text.utf16)
        let caret = min(max(0, caret), units.count)
        var start = caret
        while start > 0, !isBoundary(units[start - 1]) {
            start -= 1
        }
        while start < caret, isWhitespace(units[start]) {
            start += 1
        }
        return start
    }

    static func isBoundary(_ unit: UTF16.CodeUnit) -> Bool {
        switch unit {
        case 0x2E, 0x3F, 0x21, // . ? !
             0x3002,           // 。
             0x0A, 0x0D,       // \n \r
             0x2028, 0x2029:   // line and paragraph separators
            return true
        default:
            return false
        }
    }

    static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }
}
