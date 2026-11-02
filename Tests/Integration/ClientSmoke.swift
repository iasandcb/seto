import AppKit
import Carbon
import InputMethodKit
import Sebeol390Core

final class SmokeClient: NSObject, IMKTextInput {
    var text = ""
    var mark = NSRange(location: NSNotFound, length: 0)
    var ignoresReplacementOutsideMark = false
    var clientBundleIdentifier = "com.sebeol390.SmokeClient"
    var commitsSingleUppercaseMark = false
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
        if commitsSingleUppercaseMark, string.count == 1,
           let character = string.first, character.isASCII, character.isUppercase {
            mark = NSRange(location: NSNotFound, length: 0)
            onMark?()
            return
        }
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
    func bundleIdentifier() -> String? { clientBundleIdentifier }
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

@MainActor
private func backspace(controller: SebeolInputController, client: SmokeClient) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: Keymap.delete)!
    if !controller.handle(event, client: client), !client.text.isEmpty {
        client.text.removeLast()
        client.mark = NSRange(location: NSNotFound, length: 0)
    }
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
                ("pfjd'daB", "파이팅!", true),
                ("ntwodmr2jt?", "설치했어?", true),
                ("V3jcnt", "V3에서", true),
                ("V3jcnt pfjd'daB", "V3에서 파이팅!", true),
                ("Kjvf", "5와", false),
                ("Kjvf pfjd'daB", "5와 파이팅!", false),
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
                if keys == "pfjd'daB" || keys.hasPrefix("V3") || keys.hasPrefix("Kjvf") {
                    client.ignoresReplacementOutsideMark = true
                }
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
                for raw in keys {
                    let needsShift = !(0..<128).contains {
                        Keymap.qwertyCharacter(keyCode: UInt16($0), shift: false) == raw
                    }
                    key(raw, shift: needsShift)
                }
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
                    // A shifted digit stays in composition until its word settles (8시 vs "Int").
                    controller.commitComposition(client)
                    let expected = english ? "of←→M" : "잘←→1"
                    if client.text != expected || client.mark.length != 0 {
                        print("FAIL arrow shortcuts callbacks=\(callbacks) automatic=\(automatic) english=\(english): \(client.text)")
                        failures += 1
                    }
                    // Other modifier combinations must still reach the app.
                    for (raw, modifiers): (Character, NSEvent.ModifierFlags) in [
                        (".", [.option]), (",", [.option]), (">", [.control, .shift]),
                        ("<", [.control, .shift]), (".", [.command]),
                        (" ", [.command]), (" ", [.command, .option]),
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
        for callbacks in [false, true] {
            for (keys, expected) in [
                ("pfjdw", "파일"), ("Hpfjdw", "'파일"), ("HpfjdwH", "'파일'"),
                ("Hello", "Hello"), ("Please", "Please"), ("Git", "Git"), ("TV", "TV"),
            ] {
                cases += 1
                let client = SmokeClient()
                let controller = SebeolInputController()
                client.ignoresReplacementOutsideMark = true
                if callbacks {
                    let commit = { [weak controller, weak client] in
                        guard let client else { return }
                        controller?.commitComposition(client)
                    }
                    client.onInsert = commit
                    client.onMark = commit
                }
                var trace: [String] = []
                for raw in keys {
                    precondition(press(raw, modifiers: raw.isUppercase ? [.shift] : [], controller: controller, client: client))
                    trace.append("\(raw): \(client.text), mark=\(client.mark)")
                }
                if client.text != expected {
                    print("FAIL quoted file callbacks=\(callbacks): \(client.text), expected \(expected)")
                    print(trace.joined(separator: "\n"))
                    failures += 1
                }
            }
        }
        // Chrome commits a one-character uppercase Latin mark immediately.
        // The controller must hold the first shifted letter until the whole
        // capitalized word can be marked, so later keys are not reinterpreted
        // after Chrome ends the first mark.
        do {
            cases += 1
            let client = SmokeClient()
            client.clientBundleIdentifier = "com.google.Chrome"
            client.commitsSingleUppercaseMark = true
            let controller = SebeolInputController()
            controller.beginInputContext(bundleIdentifier: client.clientBundleIdentifier)
            for raw in "Sophia" {
                let modifiers: NSEvent.ModifierFlags = raw.isUppercase ? [.shift] : []
                precondition(press(raw, modifiers: modifiers, controller: controller, client: client))
            }
            controller.commitComposition(client)
            if client.text != "Sophia" || client.mark.length != 0 {
                print("FAIL Chrome capitalized word: \(client.text), expected Sophia")
                failures += 1
            }
        }
        // Terminal can handle Return itself when no composition is open.
        // Its output then moves the caret without another IMK event.
        for receivesReturn in [false, true] {
            cases += 1
            let client = SmokeClient()
            let controller = SebeolInputController()
            for raw in "ls" {
                precondition(press(raw, controller: controller, client: client))
            }
            if receivesReturn {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: Keymap.return)!
                if controller.handle(event, client: client) {
                    print("FAIL terminal Return was consumed")
                    failures += 1
                }
            }
            client.text += "\nfile.txt\n$ "
            for raw in "ls" {
                precondition(press(raw, controller: controller, client: client))
            }
            if client.text != "ls\nfile.txt\n$ ls" || client.mark.length != 0 {
                print("FAIL terminal next command receivesReturn=\(receivesReturn): \(client.text)")
                failures += 1
            }
        }
        // Spotlight shortcuts must pass through even with a live Hangul mark.
        for callbacks in [false, true] {
            for modifiers: NSEvent.ModifierFlags in [[.command], [.command, .option]] {
                cases += 1
                let client = SmokeClient()
                let controller = SebeolInputController()
                if callbacks {
                    let commit = { [weak controller, weak client] in
                        guard let client else { return }
                        controller?.commitComposition(client)
                    }
                    client.onInsert = commit
                    client.onMark = commit
                }
                for raw in "lfw" {
                    precondition(press(raw, controller: controller, client: client))
                }
                if press(" ", modifiers: modifiers, controller: controller, client: client)
                    || client.text != "잘" || client.mark.length != 0 {
                    print("FAIL Spotlight shortcut during composition: \(client.text)")
                    failures += 1
                }
            }
        }
        // Delete and retype at every key boundary of 나왔습니다, including
        // temporary Latin readings and shrinking a multi-syllable mark.
        for callbacks in [false, true] {
            for automatic in [false, true] {
                UserDefaults.standard.set(automatic, forKey: "autoSwitch")
                for (keys, expected) in [("hfjvf2ng3hduf", "나왔습니다"), ("hello", "hello"), ("apihgs", "api는")] {
                    for count in 1...keys.count {
                        cases += 1
                        let client = SmokeClient()
                        let controller = SebeolInputController()
                        if callbacks {
                            let commit = { [weak controller, weak client] in
                                guard let client else { return }
                                controller?.commitComposition(client)
                            }
                            client.onInsert = commit
                            client.onMark = commit
                        }
                        let reference = Session(lexicon: SharedLexicon.lexicon, autoSwitch: automatic)
                        reference.correctsTypos = Preferences.correctsTypos
                        for raw in keys {
                            _ = reference.input(raw)
                            precondition(press(raw, controller: controller, client: client))
                        }
                        for _ in 0..<count {
                            _ = reference.backspace()
                            backspace(controller: controller, client: client)
                            if client.text != reference.document {
                                print("FAIL delete callbacks=\(callbacks) automatic=\(automatic): \(keys), count=\(count), text=\(client.text), expected=\(reference.document)")
                                failures += 1
                            }
                        }
                        for raw in keys.suffix(count) {
                            _ = reference.input(raw)
                            precondition(press(raw, controller: controller, client: client))
                            if client.text != reference.document {
                                print("FAIL retype callbacks=\(callbacks) automatic=\(automatic): \(keys), count=\(count), text=\(client.text), expected=\(reference.document)")
                                failures += 1
                            }
                        }
                        if (automatic || keys == "hfjvf2ng3hduf"), client.text != expected {
                            print("FAIL restored word: \(client.text), expected \(expected)")
                            failures += 1
                        }
                    }
                }
            }
        }
        UserDefaults.standard.set(true, forKey: "autoSwitch")
        // After committing 나왔습니, the next consonant and vowel must
        // still compose as one syllable rather than remain as Latin text.
        for (keys, suffix) in [("uf", "다"), ("ud", "디")] {
            cases += 1
            let client = SmokeClient()
            let controller = SebeolInputController()
            for raw in "hfjvf2ng3hd" {
                precondition(press(raw, controller: controller, client: client))
            }
            controller.commitComposition(client)
            for raw in keys {
                precondition(press(raw, controller: controller, client: client))
                if client.mark.length == 0 { controller.commitComposition(client) }
            }
            if client.text != "나왔습니" + suffix {
                print("FAIL final syllable: \(client.text), expected 나왔습니\(suffix)")
                failures += 1
            }
        }
        // An editor may finish the mark itself while processing a deletion,
        // without sending commitComposition. The next key must start a new
        // token instead of replaying the old word beside the committed text.
        for emptyMark in [false, true] {
            for boundary in ["input", "delete", "commit", "original"] {
                cases += 1
                let client = SmokeClient()
                let controller = SebeolInputController()
                for raw in "hfjvf2ng3hduf" {
                    precondition(press(raw, controller: controller, client: client))
                }
                backspace(controller: controller, client: client)
                let kept = client.text
                client.mark = NSRange(location: emptyMark ? (kept as NSString).length : NSNotFound, length: 0)
                let expected: String
                switch boundary {
                case "input":
                    precondition(press("h", controller: controller, client: client))
                    precondition(press("f", controller: controller, client: client))
                    expected = kept + "나"
                case "delete":
                    backspace(controller: controller, client: client)
                    expected = String(kept.dropLast())
                case "original":
                    if !controller.originalString(client).string.isEmpty {
                        print("FAIL lost mark originalString returned stale text")
                        failures += 1
                    }
                    expected = kept
                default:
                    controller.commitComposition(client)
                    expected = kept
                }
                if client.text != expected {
                    print("FAIL lost mark boundary=\(boundary): \(client.text), expected \(expected)")
                    failures += 1
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
        // A number and a counter stay Korean even when their keys spell an
        // English word: Ind → 8시, Our → 9대, Olfa → 9장.
        // Web editors cannot replace committed Latin text, so "In" must not
        // be committed before d turns it into 8시.
        for web in [false, true] {
        for (keys, expected) in [("Ind ", "8시 "), ("Our ", "9대 "), ("Olfa ", "9장 "), ("MNkr ", "10개 "), ("Ind;b't ", "8시부터 "), ("Murj8 ", "1대의 "), ("Int ", "Int "), ("Open ", "Open "), ("My ", "My ")] {
            cases += 1
            let controller = SebeolInputController()
            let client = SmokeClient()
            client.ignoresReplacementOutsideMark = web
            controller.beginInputContext()
            for raw in keys {
                let modifiers: NSEvent.ModifierFlags = raw.isUppercase ? [.shift] : []
                precondition(press(raw, modifiers: modifiers, controller: controller, client: client))
            }
            controller.commitComposition(client)
            if client.text != expected || client.mark.length != 0 {
                print("FAIL number counter web=\(web) \(keys): \(client.text), expected \(expected)")
                failures += 1
            }
        }
        }
        // Terminal alone starts in English, and leaving it resets to Korean.
        do {
            let controller = SebeolInputController()
            for (bundleID, expected): (String?, String) in [
                ("com.apple.Terminal", "namu"),
                ("com.sebeol390.SmokeClient", "ㅅㅇㅎㄷ"),
                ("com.apple.Terminal", "namu"),
                (nil, "ㅅㅇㅎㄷ"),
            ] {
                cases += 1
                let client = SmokeClient()
                controller.beginInputContext(bundleIdentifier: bundleID)
                for raw in "namu" { precondition(press(raw, controller: controller, client: client)) }
                controller.commitComposition(client)
                if client.text != expected {
                    print("FAIL initial mode bundle=\(bundleID ?? "nil"): \(client.text)")
                    failures += 1
                }
            }
        }
        // A browser address bar starts in English with automatic conversion
        // and typo correction off; the next context restores Korean and the
        // preferences.
        do {
            let savedAutoSwitch = Preferences.autoSwitch
            let savedTypos = Preferences.correctsTypos
            Preferences.autoSwitch = true
            Preferences.correctsTypos = true
            let controller = SebeolInputController()
            for addressBar in [true, false, true] {
                cases += 1
                let client = SmokeClient()
                controller.beginInputContext(bundleIdentifier: "com.apple.Safari", addressBar: addressBar)
                // Like Terminal: English and no conversion in the address bar,
                // Korean in the next ordinary context.
                for raw in "namu" { precondition(press(raw, controller: controller, client: client)) }
                controller.commitComposition(client)
                if client.text != (addressBar ? "namu" : "ㅅㅇㅎㄷ") {
                    print("FAIL address bar=\(addressBar): \(client.text)")
                    failures += 1
                }
            }
            if !Preferences.autoSwitch || !Preferences.correctsTypos {
                print("FAIL address bar changed saved preferences")
                failures += 1
            }
            Preferences.autoSwitch = savedAutoSwitch
            Preferences.correctsTypos = savedTypos
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
