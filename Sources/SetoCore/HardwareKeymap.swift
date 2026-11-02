/// USB HID keyboard usages used by UIKit's UIKey.keyCode. Unlike macOS
/// virtual key codes these identify keys independently of the system layout.
public enum HardwareKeyAction: Equatable, Sendable {
    case input(Character)
    case backspace
    case toggle
    case passThrough
}

public enum HardwareKeymap {
    public static func action(
        usage: Int, shift: Bool = false,
        command: Bool = false, control: Bool = false, option: Bool = false
    ) -> HardwareKeyAction {
        guard !command, !control, !option else { return .passThrough }
        if usage == 44, shift { return .toggle }
        if usage == 42 { return .backspace }
        // Caps Lock is commonly reserved by iOS for changing system input
        // sources. Use Shift+Space rather than depending on its delivery.
        guard let pair = positions[usage] else { return .passThrough }
        return .input(shift ? pair.1 : pair.0)
    }

    private static let positions: [Int: (Character, Character)] = {
        var result: [Int: (Character, Character)] = [:]
        for (offset, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            result[4 + offset] = (character, Character(String(character).uppercased()))
        }
        for (offset, pair) in zip("1234567890", "!@#$%^&*()").enumerated() {
            result[30 + offset] = pair
        }
        result[44] = (" ", " ")
        for (offset, pair) in zip("-=[]\\", "_+{}|").enumerated() {
            result[45 + offset] = pair
        }
        for (offset, pair) in zip(";'`,./", ":\"~<>?").enumerated() {
            result[51 + offset] = pair
        }
        // ISO non-US backslash key (same symbols as its ANSI counterpart).
        result[100] = ("\\", "|")
        return result
    }()
}
