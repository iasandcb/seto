import AppKit
import Carbon
import InputMethodKit
import Sebeol390Core

final class SmokeClient: NSObject, IMKTextInput {
    var text = ""
    var mark = NSRange(location: NSNotFound, length: 0)
    var ignoresReplacementOutsideMark = false
    var onInsert: (() -> Void)?
    var onMark: (() -> Void)?
    private func value(_ input: Any?) -> String {
        (input as? NSAttributedString)?.string ?? (input as? String ?? "")
    }
    private func target(_ range: NSRange) -> NSRange {
        if range.location != NSNotFound && !(ignoresReplacementOutsideMark && mark.location == NSNotFound) { return range }
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
        let previousLayout = UserDefaults.standard.object(forKey: "keyboardLayout")
        Preferences.layout = .sebeol390
        let previousAutomatic = UserDefaults.standard.object(forKey: "autoSwitch")
        UserDefaults.standard.set(true, forKey: "autoSwitch")
        defer {
            if let previousLayout { UserDefaults.standard.set(previousLayout, forKey: "keyboardLayout") }
            else { UserDefaults.standard.removeObject(forKey: "keyboardLayout") }
            if let previousAutomatic { UserDefaults.standard.set(previousAutomatic, forKey: "autoSwitch") }
            else { UserDefaults.standard.removeObject(forKey: "autoSwitch") }
        }
        for callbacks in ["none", "insert", "mark", "both"] {
            for (keys, expected, startsInEnglish) in [
                ("gitjgs lfw uvdhc", "git은 잘 되네", true),
                ("0ts'gyvw", "컨트롤", true),
                ("'cng'g", "테스트", true),
                (";t'gs", "버튼", true),
                (";f;v", "바보", true),
                ("mgz", "흠", true),
                ("lfw", "잘", true),
                ("apihgs", "api는", true),
                ("hello", "hello", true),
                ("of", "of", true),
                ("md", "md", true),
                ("cd", "cd", false),
                ("cd ../src", "cd ../src", false),
            ] {
                cases += 1
                let client = SmokeClient()
                // The plain initializer avoids registering an input server or
                // sending synthetic keystrokes to a real application.
                let controller = SebeolInputController()
                func key(_ raw: Character, shift: Bool = false) {
                    precondition(press(raw, modifiers: shift ? [.shift] : [], controller: controller, client: client))
                }
                if startsInEnglish { key(" ", shift: true) }
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
        // Model a web editor that ignores replacement ranges outside a live
        // composition. An acronym's particle must never need that operation.
        for callbacks in [false, true] {
            for startsInEnglish in [false, true] {
                for (keys, expected) in [("AIhgs", "AI는"), ("AIyv", "AI로"), ("apihgs", "api는")] {
                    cases += 1
                    let client = SmokeClient()
                    client.ignoresReplacementOutsideMark = true
                    let controller = SebeolInputController()
                    if startsInEnglish { precondition(press(" ", modifiers: [.shift], controller: controller, client: client)) }
                    if callbacks {
                        let commit = { [weak controller, weak client] in
                            guard let client else { return }
                            controller?.commitComposition(client)
                        }
                        client.onInsert = commit
                        client.onMark = commit
                    }
                    for raw in keys {
                        let modifiers: NSEvent.ModifierFlags = raw.isUppercase ? [.shift] : []
                        precondition(press(raw, modifiers: modifiers, controller: controller, client: client))
                    }
                    controller.commitComposition(client)
                    if client.text != expected || client.mark.length != 0 {
                        print("FAIL web acronym callbacks=\(callbacks) english=\(startsInEnglish): \(keys) → \(client.text), expected \(expected)")
                        failures += 1
                    }
                }
            }
        }
        // Re-entering an input context starts in Korean, including after a
        // manually selected English mode. Leaving preserves marked text.
        for manualEnglish in [false, true] {
            cases += 1
            let controller = SebeolInputController()
            let first = SmokeClient()
            controller.beginInputContext()
            if manualEnglish {
                precondition(press(" ", modifiers: [.shift], controller: controller, client: first))
            } else {
                for raw in "hello " { precondition(press(raw, controller: controller, client: first)) }
            }
            controller.commitComposition(first)
            let second = SmokeClient()
            controller.beginInputContext()
            for raw in "namu" { precondition(press(raw, controller: controller, client: second)) }
            controller.commitComposition(second)
            if second.text != "ㅅㅇㅎㄷ" || second.mark.length != 0 {
                print("FAIL activation reset manualEnglish=\(manualEnglish): \(second.text)")
                failures += 1
            }
        }
        // Each controller reads the persisted layout, and menu selections retain
        // the current language. Reentrant editor callbacks also apply here.
        for layout in KeyboardLayout.allCases {
            for callbacks in [false, true] {
                Preferences.layout = layout
                let controller = SebeolInputController()
                let client = SmokeClient()
                if callbacks {
                    let commit = { [weak controller, weak client] in
                        guard let client else { return }
                        controller?.commitComposition(client)
                    }
                    client.onInsert = commit
                    client.onMark = commit
                }
                let keys = layout == .dubeol ? "gksrmf" : "mfskgw"
                for raw in keys { precondition(press(raw, controller: controller, client: client)) }
                // Change preferences while Hangul is marked. The next physical
                // event must commit using the old layout and start the new one.
                Preferences.layout = layout == .dubeol ? .sebeolFinal : .dubeol
                let next = Preferences.layout == .dubeol ? "r" : "k"
                precondition(press(Character(next), controller: controller, client: client))
                controller.commitComposition(client)
                cases += 1
                if client.text != "한글ㄱ" || client.mark.length != 0 {
                    print("FAIL layout switch \(layout): \(client.text)")
                    failures += 1
                }
            }
            Preferences.layout = layout
            let controller = SebeolInputController()
            let menu = controller.menu()!
            let korean = menu.items.first { $0.title == "한글 (\(layout.title))" }
            let choices = menu.items.first { $0.title == "한글 자판" }?.submenu
            cases += 1
            if korean == nil || choices?.items.count != 3 || choices?.items.first(where: { $0.state == .on })?.title != layout.title {
                print("FAIL layout menu \(layout)")
                failures += 1
            }
            if let selection = choices?.items.first(where: { $0.title == "세벌식 최종" }), let action = selection.action {
                _ = NSApp.sendAction(action, to: selection.target, from: selection)
                cases += 1
                if Preferences.layout != .sebeolFinal { failures += 1 }
            }
        }
        // Physical Shift events must use each layout's own jamo and symbols.
        Preferences.autoSwitch = false
        for (layout, keys, expected) in [
            (KeyboardLayout.sebeol390, "ifDB", "맑!"),
            (.sebeolFinal, "if@B HJKL:YUIOP", "맑? 0123456789"),
            (.dubeol, "Rk", "까"),
        ] {
            for english in [false, true] {
                Preferences.layout = layout
                let controller = SebeolInputController()
                let client = SmokeClient()
                if english { precondition(press(" ", modifiers: [.shift], controller: controller, client: client)) }
                for raw in keys {
                    let unshifted = (0..<128).contains { Keymap.qwertyCharacter(keyCode: UInt16($0), shift: false) == raw }
                    precondition(press(raw, modifiers: unshifted ? [] : [.shift], controller: controller, client: client))
                }
                controller.commitComposition(client)
                cases += 1
                let wanted = english ? keys : expected
                if client.text != wanted {
                    print("FAIL shifted layout \(layout), english=\(english): \(client.text), expected \(wanted)")
                    failures += 1
                }
            }
        }
        UserDefaults.standard.set("unknown-layout", forKey: "keyboardLayout")
        cases += 1
        if Preferences.layout != .sebeol390 { failures += 1 }
        print("IMK client integration: \(cases) cases, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
