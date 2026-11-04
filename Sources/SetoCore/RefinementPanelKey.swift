/// What a key does while the sentence refinement panel is open.
///
/// Return and Enter accept the shown suggestion, Esc keeps the original and
/// Tab shows the next suggestion, ⇧⇥ the previous one. Otherwise Shift is
/// ignored (⇧↩ accepts, ⇧esc cancels). With Command, Control or Option held
/// the key is a shortcut for the app: it closes the panel and passes through.
public enum RefinementPanelKey: Equatable, Sendable {
    case accept
    case cancel
    case next
    case previous
    case other

    public static func action(keyCode: UInt16, command: Bool, control: Bool,
                              option: Bool, shift: Bool) -> RefinementPanelKey {
        guard !command, !control, !option else { return .other }
        switch keyCode {
        case Keymap.return, keypadEnter: return .accept
        case Keymap.escape: return .cancel
        case Keymap.tab: return shift ? .previous : .next
        default: return .other
        }
    }

    /// The keypad Enter key.
    public static let keypadEnter: UInt16 = 0x4C

    /// Whether `keyCode` is one of the keys the panel consumes.
    public static func isPanelKey(_ keyCode: UInt16) -> Bool {
        action(keyCode: keyCode, command: false, control: false, option: false, shift: false) != .other
    }
}
