import Foundation

/// 공병우 세벌식 최종 (1991). Unshifted letters and digits match 390.
/// Layout checked against libhangul's hangul_keyboard_table_3final:
/// https://github.com/libhangul/libhangul/blob/main/hangul/hangulkeyboard.h
public enum LayoutFinal {
    public static func atom(for key: Character) -> KeyAtom {
        let output = overrides[key] ?? Layout390.atom(for: key).korean
        return KeyAtom(layout: .sebeolFinal, english: key, korean: output)
    }

    private static let overrides: [Character: KeyOutput] = {
        func j(_ jamo: Jamo) -> KeyOutput { .jamo(jamo) }
        func c(_ ch: Character) -> KeyOutput { .character(ch) }
        return [
            "!": j(.jong(0x11A9)), "@": j(.jong(0x11B0)),
            "#": j(.jong(0x11BD)), "$": j(.jong(0x11B5)),
            "%": j(.jong(0x11B4)), "^": c("="),
            "&": c("“"), "*": c("”"), "(": c("'"), ")": c("~"),
            "-": c(")"), "=": c(">"), "_": c(";"),
            "`": c("*"), "~": c("※"),
            "Q": j(.jong(0x11C1)), "W": j(.jong(0x11C0)),
            "E": j(.jong(0x11AC)), "R": j(.jong(0x11B6)),
            "T": j(.jong(0x11B3)), "Y": c("5"), "U": c("6"),
            "I": c("7"), "O": c("8"), "P": c("9"),
            "[": c("("), "]": c("<"), "\\": c(":"),
            "{": c("%"), "}": c("/"), "|": c("\\"),
            "A": j(.jong(0x11AE)), "S": j(.jong(0x11AD)),
            "D": j(.jong(0x11B2)), "F": j(.jong(0x11B1)),
            "G": j(.jung(0x1164)), "H": c("0"),
            "J": c("1"), "K": c("2"), "L": c("3"),
            ":": c("4"), "\"": c("·"),
            "Z": j(.jong(0x11BE)), "X": j(.jong(0x11B9)),
            "C": j(.jong(0x11BF)), "V": j(.jong(0x11AA)),
            "B": c("?"), "N": c("-"), "M": c("\""),
            "<": c(","), ">": c("."), "?": c("!"),
        ]
    }()
}
