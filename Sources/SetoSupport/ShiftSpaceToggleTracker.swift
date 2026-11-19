/// Decides whether Shift+Space is a language toggle. Typing `?` (Shift+/) and
/// then Space with Shift still held must stay a normal space, so the toggle
/// only counts when no other key was typed since Shift went down.
public struct ShiftSpaceToggleTracker: Sendable {
    private var shiftDown = false
    private var otherKeyTyped = false

    public init() {}

    /// Feed every flagsChanged event with the current Shift state.
    public mutating func shiftChanged(isDown: Bool) {
        if isDown && !shiftDown {
            otherKeyTyped = false
        }
        shiftDown = isDown
    }

    /// Feed every keyDown. Returns true if this key is a Shift+Space toggle.
    public mutating func keyDown(isSpace: Bool, shift: Bool) -> Bool {
        if isSpace {
            return shift && !otherKeyTyped
        }
        if shift {
            otherKeyTyped = true
        }
        return false
    }
}
