import Foundation

/// Standard Korean two-set QWERTY layout used by the touch keyboard.
public enum LayoutDubeol {
    public static func atom(for key: Character) -> KeyAtom {
        let lower = Character(String(key).lowercased())
        let letters = Array("qwertyuiopasdfghjklzxcvbnm")
        let scalars: [UInt32] = [0x1107,0x110C,0x1103,0x1100,0x1109,0x116D,0x1167,0x1163,0x1162,0x1166,0x1106,0x1102,0x110B,0x1105,0x1112,0x1169,0x1165,0x1161,0x1175,0x110F,0x1110,0x110E,0x1111,0x1172,0x116E,0x1173]
        guard let index = letters.firstIndex(of: lower) else { return KeyAtom(layout: .dubeol, english: key, korean: .character(key)) }
        let shifted: [Character: UInt32] = ["Q":0x1108,"W":0x110D,"E":0x1104,"R":0x1101,"T":0x110A,"O":0x1164,"P":0x1168]
        let scalar = shifted[key] ?? scalars[index]
        return KeyAtom(layout: .dubeol, english: key, korean: .jamo(Jamo(scalar: scalar, kind: scalar >= 0x1161 ? .jungseong : .choseong)))
    }

    private static let finals: [UInt32: UInt32] = [0x1100:0x11A8,0x1101:0x11A9,0x1102:0x11AB,0x1103:0x11AE,0x1105:0x11AF,0x1106:0x11B7,0x1107:0x11B8,0x1109:0x11BA,0x110A:0x11BB,0x110B:0x11BC,0x110C:0x11BD,0x110E:0x11BE,0x110F:0x11BF,0x1110:0x11C0,0x1111:0x11C1,0x1112:0x11C2]
    public static func final(forInitial jamo: Jamo) -> Jamo? { finals[jamo.scalar].map(Jamo.jong) }
    public static func initial(forFinal jamo: Jamo) -> Jamo? { finals.first { $0.value == jamo.scalar }.map { Jamo.cho($0.key) } }
}
