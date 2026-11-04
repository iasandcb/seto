/// Finds the sentence the caret is in or has just finished.
///
/// Offsets are UTF-16, matching NSRange in IMK and Accessibility. Every
/// boundary, closer and space looked at is a BMP character, so scanning code
/// units never splits a surrogate pair.
public enum SentenceBoundary {
    /// The sentence to refine for a caret at `caret`, as UTF-16 offsets with
    /// `upperBound <= caret`.
    ///
    /// When the caret follows sentence-ending punctuation (`.` `?` `!` `。`
    /// `！` `？` `…`, possibly a run like `?!` or `...`), optionally followed
    /// by closing quotes or brackets and then spaces or tabs, the range is
    /// the sentence that just ended: it includes the punctuation and closers
    /// but not the trailing spaces. Otherwise it runs from just after the
    /// last boundary (`.` `?` `!` `。` `！` `？` or a line break) to the
    /// caret. Leading whitespace is skipped either way. An empty range means
    /// there is nothing to refine.
    public static func range(in text: String, before caret: Int) -> Range<Int> {
        let units = Array(text.utf16)
        let caret = min(max(0, caret), units.count)

        var afterCloser = caret
        while afterCloser > 0, isHorizontalSpace(units[afterCloser - 1]) {
            afterCloser -= 1
        }
        var punctuation = afterCloser
        while punctuation > 0, isCloser(units[punctuation - 1]) {
            punctuation -= 1
        }
        let closersEnd = punctuation
        while punctuation > 0, isTerminator(units[punctuation - 1]) {
            punctuation -= 1
        }

        if punctuation < closersEnd {
            // The caret follows a finished sentence. Without any text before
            // its punctuation there is nothing to refine.
            let start = sentenceStart(units, before: punctuation)
            return start < punctuation ? start..<afterCloser : caret..<caret
        }
        return sentenceStart(units, before: caret)..<caret
    }

    /// Just after the last boundary before `end`, with leading whitespace
    /// skipped. Never past `end`.
    private static func sentenceStart(_ units: [UTF16.CodeUnit], before end: Int) -> Int {
        var start = end
        while start > 0, !isBoundary(units[start - 1]) {
            start -= 1
        }
        while start < end, isWhitespace(units[start]) {
            start += 1
        }
        return start
    }

    static func isBoundary(_ unit: UTF16.CodeUnit) -> Bool {
        switch unit {
        case 0x2E, 0x3F, 0x21,  // . ? !
             0x3002,            // 。
             0xFF01, 0xFF1F,    // ！ ？
             0x0A, 0x0D,        // \n \r
             0x2028, 0x2029:    // line and paragraph separators
            return true
        default:
            return false
        }
    }

    /// Punctuation that ends a sentence. The ellipsis ends one only at the
    /// caret; mid-text it is often a pause, so it is not a boundary.
    static func isTerminator(_ unit: UTF16.CodeUnit) -> Bool {
        switch unit {
        case 0x2E, 0x3F, 0x21, 0x3002, 0xFF01, 0xFF1F, // . ? ! 。 ！ ？
             0x2026:                                    // …
            return true
        default:
            return false
        }
    }

    static func isCloser(_ unit: UTF16.CodeUnit) -> Bool {
        switch unit {
        case 0x201D, 0x2019, 0x22, 0x27, // ” ’ " '
             0x29, 0x5D, 0x7D,           // ) ] }
             0x300D, 0x300F,             // 」 』
             0x300B, 0x3009,             // 》 〉
             0xFF09:                     // ）
            return true
        default:
            return false
        }
    }

    /// Spaces and tabs; line breaks end a sentence and are never skipped.
    static func isHorizontalSpace(_ unit: UTF16.CodeUnit) -> Bool {
        switch unit {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
            return false
        default:
            return isWhitespace(unit)
        }
    }

    static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }
}
