import AppKit
import Carbon
import InputMethodKit
import Sebeol390Core

final class SmokeClient: NSObject, IMKTextInput {
    var text = ""
    var mark = NSRange(location: NSNotFound, length: 0)
    var onInsert: (() -> Void)?
    var onMark: (() -> Void)?
    private func value(_ input: Any?) -> String {
        (input as? NSAttributedString)?.string ?? (input as? String ?? "")
    }
    private func target(_ range: NSRange) -> NSRange {
        if range.location != NSNotFound { return range }
        return mark.location != NSNotFound ? mark : NSRange(location: (text as NSString).length, length: 0)
    }
    func insertText(_ input: Any?, replacementRange: NSRange) {
        let replacement = target(replacementRange)
        text = (text as NSString).replacingCharacters(in: replacement, with: value(input))
        mark = NSRange(location: NSNotFound, length: 0)
        onInsert?()
    }
    func setMarkedText(_ input: Any?, selectionRange: NSRange, replacementRange: NSRange) {
        let replacement = target(replacementRange)
        let string = value(input)
        text = (text as NSString).replacingCharacters(in: replacement, with: string)
        mark = NSRange(location: replacement.location, length: (string as NSString).length)
        onMark?()
    }
    func selectedRange() -> NSRange { NSRange(location: (text as NSString).length, length: 0) }
    func markedRange() -> NSRange { mark }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { nil }
    func length() -> Int { (text as NSString).length }
    func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>?) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>?) -> [AnyHashable: Any]? { [:] }
    func validAttributesForMarkedText() -> [Any]? { [] }
    func overrideKeyboard(withKeyboardNamed name: String?) {}
    func selectMode(_ mode: String?) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String? { "com.sebeol390.SmokeClient" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { true }
    func uniqueClientIdentifierString() -> String? { "smoke" }
    func string(from range: NSRange, actualRange: NSRangePointer?) -> String? { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
}

@MainActor
private func press(_ raw: Character, modifiers: NSEvent.ModifierFlags = [], controller: SebeolInputController, client: SmokeClient) -> Bool {
    let shift = modifiers.contains(.shift)
    let code = (0..<128).first { Keymap.qwertyCharacter(keyCode: UInt16($0), shift: shift) == raw }!
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: String(raw), charactersIgnoringModifiers: String(raw), isARepeat: false, keyCode: UInt16(code))!
    return controller.handle(event, client: client)
}

@main struct ClientSmoke {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures = 0
        var cases = 0
        let previousAutomatic = UserDefaults.standard.object(forKey: "autoSwitch")
        UserDefaults.standard.set(true, forKey: "autoSwitch")
        defer {
            if let previousAutomatic { UserDefaults.standard.set(previousAutomatic, forKey: "autoSwitch") }
            else { UserDefaults.standard.removeObject(forKey: "autoSwitch") }
        }
        for callbacks in ["none", "insert", "mark", "both"] {
            for (keys, expected) in [
                ("gitjgs lfw uvdhc", "git은 잘 되네"),
                ("mgz", "흠"),
                ("lfw", "잘"),
                ("apihgs", "api는"),
                ("hello", "hello"),
                ("of", "of"),
                ("md", "md"),
            ] {
                cases += 1
                let client = SmokeClient()
                // The plain initializer avoids registering an input server or
                // sending synthetic keystrokes to a real application.
                let controller = SebeolInputController()
                func key(_ raw: Character, shift: Bool = false) {
                    precondition(press(raw, modifiers: shift ? [.shift] : [], controller: controller, client: client))
                }
                key(" ", shift: true)
                let commit = { [weak controller, weak client] in
                    guard let client else { return }
                    controller?.commitComposition(client)
                }
                if callbacks == "insert" || callbacks == "both" { client.onInsert = commit }
                if callbacks == "mark" || callbacks == "both" { client.onMark = commit }
                for raw in keys { key(raw) }
                if client.text != expected {
                    print("FAIL callbacks=\(callbacks): \(keys) → \(client.text), expected \(expected)")
                    failures += 1
                }
                // A real commit outside a client edit must still unmark the
                // completed text, including when insertText echoes a commit.
                controller.commitComposition(client)
                if client.text != expected || client.mark.length != 0 {
                    print("FAIL explicit commit callbacks=\(callbacks): \(client.text)")
                    failures += 1
                }
            }
            for automatic in [false, true] {
                UserDefaults.standard.set(automatic, forKey: "autoSwitch")
                for english in [false, true] {
                    cases += 1
                    let client = SmokeClient()
                    let controller = SebeolInputController()
                    if english { precondition(press(" ", modifiers: [.shift], controller: controller, client: client)) }
                    let commit = { [weak controller, weak client] in
                        guard let client else { return }
                        controller?.commitComposition(client)
                    }
                    if callbacks == "insert" || callbacks == "both" { client.onInsert = commit }
                    if callbacks == "mark" || callbacks == "both" { client.onMark = commit }
                    for raw: Character in english ? "of" : "lfw" {
                        precondition(press(raw, controller: controller, client: client))
                    }
                    precondition(press(",", modifiers: [.control], controller: controller, client: client))
                    precondition(press(".", modifiers: [.control], controller: controller, client: client))
                    precondition(press("M", modifiers: [.shift], controller: controller, client: client))
                    let expected = english ? "of←→M" : "잘←→1"
                    if client.text != expected || client.mark.length != 0 {
                        print("FAIL arrow shortcuts callbacks=\(callbacks) automatic=\(automatic) english=\(english): \(client.text)")
                        failures += 1
                    }
                    // Other modifier combinations must still reach the app.
                    for (raw, modifiers): (Character, NSEvent.ModifierFlags) in [
                        (".", [.option]), (",", [.option]), (">", [.control, .shift]),
                        ("<", [.control, .shift]), (".", [.command]),
                        (".", [.control, .option]), (".", [.control, .function]),
                    ] {
                        if press(raw, modifiers: modifiers, controller: controller, client: client) {
                            print("FAIL intercepted shortcut: \(raw), \(modifiers.rawValue)")
                            failures += 1
                        }
                    }
                    if client.text != expected { failures += 1 }
                }
            }
        }
        print("IMK client integration: \(cases) cases, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
