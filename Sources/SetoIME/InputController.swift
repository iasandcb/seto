import AppKit
import Carbon
import InputMethodKit
import SetoCore

@objc(SebeolInputController)
final class SebeolInputController: IMKInputController, NSMenuDelegate {
    private static func makeSession(mode: Language = .korean) -> Session {
        let session = Session(
            lexicon: SharedLexicon.lexicon,
            autoSwitch: Preferences.autoSwitch,
            mode: mode,
            typos: SharedTypoLog.store,
            layout: Preferences.layout
        )
        session.correctsTypos = Preferences.correctsTypos
        return session
    }
    private var session = SebeolInputController.makeSession()
    private var sawCapsLockDown = false
    private var active = false
    private var clientUpdateDepth = 0
    private var unmarkedSelection: NSRange?
    private var unmarkedSelectionAdvance = 0
    /// Terminal and a browser address bar start with automatic conversion off
    /// for this input context. A manual toggle can override that until the
    /// next context activation.
    private var contextAutoSwitchOverride: Bool?
    /// A browser address bar also turns typo correction off, the same way.
    private var contextCorrectsTyposOverride: Bool?
    /// A browser context that was not an address bar at activation. The
    /// browser may move accessibility focus after IMK activates, so the first
    /// typed key checks once more.
    private var pendingAddressBarCheck: String?
    /// ⇧⌘L sentence refinement and its panel, shared by every controller so
    /// whichever one receives a panel key handles it.
    private var refinement: SentenceRefinementController { .shared }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // Terminal and browser address bars start in English; other input
        // contexts start in Korean.
        // A fresh session
        // also drops the previous field's English context and undo history.
        if !active {
            let bundleIdentifier = (sender as? IMKTextInput)?.bundleIdentifier()
            beginInputContext(
                bundleIdentifier: bundleIdentifier,
                addressBar: FocusedElementReader.addressBarFocused(bundleIdentifier: bundleIdentifier)
            )
        }
        active = true
        let owner = ObjectIdentifier(self)
        let mode = session.mode
        let layout = session.layout
        let autoSwitch = session.autoSwitch
        // IMK's Objective-C callbacks run on the main thread but do not carry
        // Swift actor annotations. Bridge this menu into the main actor below.
        nonisolated(unsafe) let statusMenu = NSMenu(title: "세토")
        statusMenu.delegate = self
        MainActor.assumeIsolated {
            ModeStatusItem.shared.activate(owner: owner, mode: mode, layout: layout,
                                           autoSwitch: autoSwitch, menu: statusMenu)
        }
    }

    // Kept separate from IMK activation so the reset can be exercised by a
    // mock client without an InputMethodKit server connection.
    func beginInputContext(bundleIdentifier: String? = nil, addressBar: Bool = false) {
        let isTerminal = bundleIdentifier == "com.apple.Terminal"
        let mode: Language = isTerminal || addressBar ? .english : .korean
        contextAutoSwitchOverride = isTerminal || addressBar ? false : nil
        contextCorrectsTyposOverride = addressBar ? false : nil
        pendingAddressBarCheck = !addressBar && AddressBar.isBrowser(bundleIdentifier) ? bundleIdentifier : nil
        session = Self.makeSession(mode: mode)
        session.autoSwitch = contextAutoSwitchOverride ?? Preferences.autoSwitch
        session.correctsTypos = contextCorrectsTyposOverride ?? Preferences.correctsTypos
        sawCapsLockDown = false
        unmarkedSelection = nil
        unmarkedSelectionAdvance = 0
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask = NSEvent.EventTypeMask([.keyDown, .flagsChanged])
        return Int(mask.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        // The refinement panel takes Return, Tab and Esc; other keys close it
        // and continue below.
        if event.type == .keyDown, let handled = refinement.handleKey(event, client: client) {
            return handled
        }
        reconcileComposition(client: client)
        if event.type == .flagsChanged {
            if IsSecureEventInputEnabled() {
                apply(session.discard(), client: client)
                return false
            }
            syncPreferences(client: client)
            return handleFlags(event, client: client)
        }
        guard event.type == .keyDown else { return false }

        let secure = IsSecureEventInputEnabled()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        SharedTypingStatistics.store.record(
            keyCode: event.keyCode,
            shift: flags.contains(.shift),
            shortcut: !flags.intersection([.command, .control, .option]).isEmpty,
            secure: secure
        )
        if secure {
            apply(session.discard(), client: client)
            return false
        }
        if let browser = pendingAddressBarCheck,
           flags.intersection([.command, .control, .option]).isEmpty {
            pendingAddressBarCheck = nil
            if FocusedElementReader.addressBarFocused(bundleIdentifier: browser) {
                beginInputContext(bundleIdentifier: browser, addressBar: true)
                updateModeStatus()
            }
        }
        syncPreferences(client: client)
        let shortcutFlags = flags.intersection([.command, .control, .option, .shift])
        let isControlShiftHotkey = flags.contains(.control) && flags.contains(.shift)
            && !flags.contains(.command) && !flags.contains(.option)
        let isAutoSwitchHotkeyKey = event.keyCode == 0x28 // Physical K
        if isControlShiftHotkey, isAutoSwitchHotkeyKey {
            toggleAutoSwitch()
            return true
        }
        // ⇧⌘L must be checked before Command shortcuts pass through below.
        if shortcutFlags == [.shift, .command], event.keyCode == 0x25 { // Physical L
            apply(session.commitDisplayed(), client: client)
            return refinement.begin(client: client, owner: self)
        }
        if shortcutFlags == .control {
            let arrow: Character?
            switch Keymap.qwertyCharacter(keyCode: event.keyCode, shift: false) {
            case ",": arrow = "←"
            case ".": arrow = "→"
            default: arrow = nil
            }
            if let arrow {
                apply(session.input(arrow), client: client)
                return true
            }
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            apply(session.commitDisplayed(), client: client)
            return false
        }

        if event.keyCode == Keymap.delete {
            let update = session.backspace()
            updateModeStatus()
            guard update.field != .none else {
                // The app moves the caret after handle() returns. Do not
                // mistake that expected deletion for an external edit.
                unmarkedSelection = nil
                unmarkedSelectionAdvance = 0
                return false
            }
            apply(update, client: client)
            return true
        }
        if Keymap.isNavigation(event.keyCode) {
            let endingRun = event.keyCode == Keymap.return
            apply(session.commitDisplayed(endingRun: endingRun), client: client)
            return false
        }

        let shift = flags.contains(.shift)
        if event.keyCode == Keymap.space && shift {
            apply(session.toggle(), client: client)
            return true
        }
        guard let character = Keymap.qwertyCharacter(keyCode: event.keyCode, shift: shift) else {
            apply(session.commitDisplayed(), client: client)
            return false
        }
        apply(session.input(character), client: client)
        return true
    }

    override func commitComposition(_ sender: Any!) {
        // Some editors synchronously ask us to commit while insertText or
        // setMarkedText is still applying our update. This is an echo of that
        // edit, not a new boundary: clearing keys here loses Latin prefixes
        // before they can be recognized as Hangul (lfw → 잘).
        guard clientUpdateDepth == 0 else { return }
        refinement.closeAfterCommit(owner: self)
        guard let client = sender as? IMKTextInput else { return }
        reconcileComposition(client: client)
        apply(session.commitDisplayed(), client: client)
    }

    /// ESC and a client that ends composition on '.' ask for the original
    /// keystrokes. Those keys are `mr2jt` for 했어, so return the Hangul
    /// that is actually marked.
    override func originalString(_ sender: Any!) -> NSAttributedString! {
        if let client = sender as? IMKTextInput {
            reconcileComposition(client: client)
        }
        return NSAttributedString(string: session.preedit)
    }

    override func cancelComposition() {
        guard clientUpdateDepth == 0 else { return }
        guard let client = client() else { return }
        reconcileComposition(client: client)
        apply(session.commitDisplayed(), client: client)
    }

    /// Editors can end a mark or move the caret without an IMK event. Terminal
    /// can handle Return itself while English is unmarked, leaving the previous
    /// command in our token (ls + ls → ㅈㄴㅈㄴ). Start fresh without editing
    /// text or recording a retype from a token we no longer own.
    private func reconcileComposition(client: IMKTextInput) {
        guard clientUpdateDepth == 0 else { return }
        if session.preedit.isEmpty {
            guard let expected = unmarkedSelection else { return }
            let selection = client.selectedRange()
            // Chrome editors may report either the old caret (before our
            // insertion) or an optimistic caret beyond it after replacing
            // neighbouring placeholder text. Both can differ by up to the
            // length of our own edit; a larger move still signals a new field
            // position, as in Terminal.
            let selectionIsOwnEdit = selection.location != NSNotFound
                && expected.length == 0 && selection.length == 0
                && abs(selection.location - expected.location) <= unmarkedSelectionAdvance
            guard selection.location != NSNotFound, selection != expected, !selectionIsOwnEdit else { return }
        } else {
            let mark = client.markedRange()
            guard mark.location == NSNotFound || mark.length == 0 else { return }
        }
        session = Self.makeSession(mode: session.mode)
        unmarkedSelection = nil
        unmarkedSelectionAdvance = 0
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        refinement.close(ownedBy: self)
        active = false
        let owner = ObjectIdentifier(self)
        MainActor.assumeIsolated {
            ModeStatusItem.shared.hide(owner: owner)
        }
        super.deactivateServer(sender)
    }

    private func updateModeStatus() {
        guard active else { return }
        let owner = ObjectIdentifier(self)
        let mode = session.mode
        let layout = session.layout
        let autoSwitch = session.autoSwitch
        MainActor.assumeIsolated {
            ModeStatusItem.shared.update(owner: owner, mode: mode, layout: layout,
                                         autoSwitch: autoSwitch)
        }
    }

    func menuNeedsUpdate(_ statusMenu: NSMenu) {
        statusMenu.removeAllItems()
        statusMenu.autoenablesItems = false
        guard let current = menu() else { return }
        for entry in current.items {
            current.removeItem(entry)
            statusMenu.addItem(entry)
        }
    }

    override func menu() -> NSMenu! {
        syncPreferences()
        let menu = NSMenu(title: "세토")
        // Keep the refine item's isEnabled; every other item is always enabled.
        menu.autoenablesItems = false
        let auto = menu.addItem(withTitle: "자동 한/영 전환 (⌃⇧K)", action: #selector(toggleAutoSwitch(_:)), keyEquivalent: "")
        auto.state = session.autoSwitch ? .on : .off
        auto.target = self
        let typos = menu.addItem(withTitle: "오타 자동 교정", action: #selector(toggleTypoCorrection(_:)), keyEquivalent: "")
        typos.state = session.correctsTypos ? .on : .off
        typos.target = self
        menu.addItem(.separator())
        let refine = menu.addItem(withTitle: "현재 문장 다듬기 (⇧⌘L)", action: #selector(refineInput(_:)), keyEquivalent: "")
        refine.target = self
        if #available(macOS 26.0, *) {
            refine.isEnabled = SentenceRefiner.unavailableReason == nil
        } else {
            refine.isEnabled = false
        }
        let korean = menu.addItem(withTitle: "한글 (\(session.layout.title))", action: #selector(selectKorean(_:)), keyEquivalent: "")
        korean.state = session.mode == .korean ? .on : .off
        korean.target = self
        let english = menu.addItem(withTitle: "영문 (QWERTY)", action: #selector(selectEnglish(_:)), keyEquivalent: "")
        english.state = session.mode == .english ? .on : .off
        english.target = self
        menu.addItem(.separator())
        let layouts = menu.addItem(withTitle: "한글 자판", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: "한글 자판")
        for layout in KeyboardLayout.allCases {
            let entry = layoutMenu.addItem(withTitle: layout.title, action: #selector(selectLayout(_:)), keyEquivalent: "")
            entry.representedObject = layout.rawValue
            entry.state = session.layout == layout ? .on : .off
            entry.target = self
        }
        layouts.submenu = layoutMenu
        menu.addItem(.separator())
        let dictionaries = menu.addItem(withTitle: "단어 사전", action: nil, keyEquivalent: "")
        let dictionaryMenu = NSMenu(title: "단어 사전")
        for (title, filename) in [("영어 사전 편집…", "english-words.txt"), ("영어 추가 사전 편집…", "english-extra.txt"), ("한국어 사전 편집…", "korean-words.txt"), ("한국어 오타 보호 사전 편집…", "korean-valid.txt")] {
            let entry = dictionaryMenu.addItem(withTitle: title, action: #selector(editDictionary(_:)), keyEquivalent: "")
            entry.representedObject = filename
            entry.target = self
        }
        dictionaryMenu.addItem(.separator())
        let reload = dictionaryMenu.addItem(withTitle: "수정한 사전 다시 불러오기", action: #selector(reloadDictionaries(_:)), keyEquivalent: "")
        reload.target = self
        dictionaries.submenu = dictionaryMenu
        let statistics = menu.addItem(withTitle: "타자 통계", action: nil, keyEquivalent: "")
        let detail = NSMenu(title: "타자 통계")
        let snapshot = SharedTypingStatistics.store.snapshot()
        for (label, counts) in [("이 맥 오늘", snapshot.today), ("이 맥 누적", snapshot.total)] {
            let ratio = counts.typed == 0 ? "—" : String(format: "%.2f%%", counts.backspaceRatio * 100)
            detail.addItem(withTitle: "\(label): \(ratio) (백스페이스 \(counts.backspaces)회 / 입력 \(counts.typed)타)", action: nil, keyEquivalent: "")
        }
        detail.addItem(.separator())
        let (history, syncStatus) = MainActor.assumeIsolated {
            (StatisticsSync.shared.combinedHistory(), StatisticsSync.shared.status)
        }
        let todayKey = SharedTypingStatistics.store.dayKey(at: Date())
        let today = history[todayKey] ?? .init()
        detail.addItem(withTitle: "맥 통합 오늘: \(today.typed)타 · 백스페이스 \(today.backspaces)회", action: nil, keyEquivalent: "")
        let daysMenu = NSMenu(title: "일별 통합")
        for day in history.keys.sorted(by: >).prefix(30) {
            let counts = history[day]!
            let ratio = counts.typed == 0 ? "—" : String(format: "%.2f%%", counts.backspaceRatio * 100)
            daysMenu.addItem(withTitle: "\(day): \(counts.typed)타 · 삭제 \(counts.backspaces)회 · \(ratio)", action: nil, keyEquivalent: "")
        }
        let days = detail.addItem(withTitle: "최근 30개 기록일 (한국 시간)", action: nil, keyEquivalent: "")
        days.submenu = daysMenu
        detail.addItem(withTitle: syncStatus, action: nil, keyEquivalent: "")
        let refresh = detail.addItem(withTitle: "지금 동기화", action: #selector(syncStatistics(_:)), keyEquivalent: "")
        refresh.target = self
        detail.addItem(.separator())
        detail.addItem(withTitle: "비율 = 백스페이스 횟수 ÷ 입력 타수", action: nil, keyEquivalent: "")
        detail.addItem(withTitle: "입력 타수: 자모·문자·공백·Enter·Tab", action: nil, keyEquivalent: "")
        statistics.submenu = detail
        return menu
    }

    @objc private func syncStatistics(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { StatisticsSync.shared.sync() }
    }

    @objc private func refineInput(_ sender: Any?) {
        guard let client = client() else { return }
        apply(session.commitDisplayed(), client: client)
        _ = refinement.begin(client: client, owner: self)
    }

    @objc private func editDictionary(_ sender: NSMenuItem) {
        do {
            let directory = try SharedLexicon.editableDirectory()
            guard let filename = sender.representedObject as? String else { return }
            let url = directory.appendingPathComponent(filename)
            NSWorkspace.shared.open(url)
        } catch {
            showDictionaryError(error)
        }
    }

    @objc private func reloadDictionaries(_ sender: Any?) {
        do {
            let loaded = try Lexicon.load(from: SharedLexicon.editableDirectory())
            if let client = client() { apply(session.commitDisplayed(), client: client) }
            let replacement = Session(lexicon: loaded, autoSwitch: session.autoSwitch,
                                      mode: session.mode, typos: SharedTypoLog.store, layout: session.layout)
            replacement.correctsTypos = session.correctsTypos
            SharedLexicon.lexicon = loaded
            session = replacement
        } catch {
            showDictionaryError(error)
        }
    }

    private func showDictionaryError(_ error: Error) {
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = "사전을 열 수 없습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleAutoSwitch(_ sender: Any?) {
        toggleAutoSwitch()
    }

    private func toggleAutoSwitch() {
        if let override = contextAutoSwitchOverride {
            contextAutoSwitchOverride = !override
        } else {
            Preferences.autoSwitch = !Preferences.autoSwitch
        }
        session.autoSwitch = contextAutoSwitchOverride ?? Preferences.autoSwitch
        updateModeStatus()
    }

    @objc private func toggleTypoCorrection(_ sender: Any?) {
        session.correctsTypos.toggle()
        if contextCorrectsTyposOverride != nil {
            contextCorrectsTyposOverride = session.correctsTypos
        } else {
            Preferences.correctsTypos = session.correctsTypos
        }
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = KeyboardLayout(rawValue: raw) else { return }
        Preferences.layout = layout
        syncPreferences()
        updateModeStatus()
    }

    private func syncPreferences(client inputClient: (any IMKTextInput)? = nil) {
        if session.layout != Preferences.layout {
            let update = session.commitDisplayed()
            if update.field != .none, let client = inputClient ?? client() {
                apply(update, client: client)
            }
            session = Self.makeSession(mode: session.mode)
            updateModeStatus()
        }
        session.autoSwitch = contextAutoSwitchOverride ?? Preferences.autoSwitch
        session.correctsTypos = contextCorrectsTyposOverride ?? Preferences.correctsTypos
        updateModeStatus()
    }

    @objc private func selectKorean(_ sender: Any?) {
        if let client = client() {
            apply(session.forceMode(.korean), client: client)
        } else {
            _ = session.forceMode(.korean)
        }
        updateModeStatus()
    }

    @objc private func selectEnglish(_ sender: Any?) {
        if let client = client() {
            apply(session.forceMode(.english), client: client)
        } else {
            _ = session.forceMode(.english)
        }
        updateModeStatus()
    }

    private func handleFlags(_ event: NSEvent, client: IMKTextInput) -> Bool {
        guard event.keyCode == Keymap.capsLock else { return false }
        let down = event.modifierFlags.contains(.capsLock)
        if down && !sawCapsLockDown {
            sawCapsLockDown = true
            apply(session.toggle(), client: client)
            CapsLockReset.turnOff()
            return true
        }
        if !down {
            sawCapsLockDown = false
        }
        return true
    }

    private func apply(_ update: SessionUpdate, client: IMKTextInput) {
        let initialDocumentLength = client.length()
        let initialMarkedLength = markedLength(client)
        let intendedAdvance: Int
        switch update.field {
        case .unmark(let text), .insert(let text):
            intendedAdvance = (text as NSString).length - initialMarkedLength
        case .insertReplacing(let utf16, let text):
            intendedAdvance = (text as NSString).length - utf16
        case .clearMarkThenInsert(let utf16, let text):
            intendedAdvance = (text as NSString).length - (utf16 + initialMarkedLength)
        case .rewrite(let utf16, let text, let thenMark) where thenMark.isEmpty:
            intendedAdvance = (text as NSString).length - utf16
        case .none, .mark, .replaceBeforeCaret, .insertThenMark, .insertReplacingThenMark,
             .clearMarkThenMark, .rewrite:
            intendedAdvance = 0
        }
        clientUpdateDepth += 1
        defer {
            if clientUpdateDepth == 1 {
                unmarkedSelection = nil
                unmarkedSelectionAdvance = 0
                if session.preedit.isEmpty {
                    let selection = client.selectedRange()
                    if selection.location != NSNotFound {
                        unmarkedSelection = selection
                        let observedAdvance = client.length() - initialDocumentLength
                        unmarkedSelectionAdvance = max(0, intendedAdvance, observedAdvance)
                    }
                }
            }
            clientUpdateDepth -= 1
        }
        updateModeStatus()
        let notFound = NSRange(location: NSNotFound, length: NSNotFound)
        switch update.field {
        case .none:
            return
        case .unmark(let text):
            guard !text.isEmpty else { return }
            insertCommitting(text, client: client)
        case .insert(let text):
            guard !text.isEmpty else { return }
            insertCommitting(text, client: client)
        case .mark(let text):
            setMarked(text, replacement: markReplacement(text, client: client), client: client)
        case .replaceBeforeCaret(let utf16, let text):
            setMarked(text, replacement: rangeBeforeCaret(utf16, client: client), client: client)
        case .insertThenMark(let insert, let mark):
            if !insert.isEmpty {
                client.insertText(insert, replacementRange: notFound)
            }
            setMarked(mark, replacement: notFound, client: client)
        case .insertReplacing(let utf16, let text):
            client.insertText(text, replacementRange: rangeBeforeCaret(utf16, client: client))
        case .insertReplacingThenMark(let utf16, let insert, let mark):
            client.insertText(insert, replacementRange: rangeBeforeCaret(utf16, client: client))
            setMarked(mark, replacement: notFound, client: client)
        case .clearMarkThenInsert(let utf16, let text):
            let span = utf16 + markedLength(client)
            client.insertText(text, replacementRange: rangeBeforeCaret(span, client: client))
        case .clearMarkThenMark(let utf16, let text):
            let span = utf16 + markedLength(client)
            setMarked(text, replacement: rangeBeforeCaret(span, client: client), client: client)
        case .rewrite(let utf16, let text, let thenMark):
            let range = rangeBeforeCaret(utf16, client: client)
            if thenMark.isEmpty {
                client.insertText(text, replacementRange: range)
            } else if text.isEmpty {
                setMarked(thenMark, replacement: range, client: client)
            } else {
                client.insertText(text, replacementRange: range)
                setMarked(thenMark, replacement: notFound, client: client)
            }
        }
    }

    /// A mark is the Hangul being composed. Replacing that range commits it.
    /// `NSNotFound` inserts at the caret instead, and the client then keeps
    /// the raw keys (`mr2jt`) and puts the period after a space.
    private func insertCommitting(_ text: String, client: IMKTextInput) {
        let marked = client.markedRange()
        if marked.location != NSNotFound, marked.length > 0 {
            client.insertText(text, replacementRange: marked)
        } else {
            let notFound = NSRange(location: NSNotFound, length: NSNotFound)
            client.insertText(text, replacementRange: notFound)
        }
    }

    /// Growing a composition replaces the mark when the range is left unset.
    /// Shrinking it that way can commit the tail instead of deleting it, so
    /// Backspace passes the marked range and the shorter reading replaces it.
    private func markReplacement(_ text: String, client: IMKTextInput) -> NSRange {
        let notFound = NSRange(location: NSNotFound, length: NSNotFound)
        let existing = client.markedRange()
        guard existing.location != NSNotFound, existing.length > 0 else { return notFound }
        if (text as NSString).length < existing.length {
            return existing
        }
        return notFound
    }

    private func setMarked(_ text: String, replacement: NSRange, client: IMKTextInput) {
        let end = (text as NSString).length
        client.setMarkedText(
            marked(text),
            selectionRange: NSRange(location: end, length: 0),
            replacementRange: replacement
        )
    }

    private func markedLength(_ client: IMKTextInput) -> Int {
        let range = client.markedRange()
        if range.location == NSNotFound { return 0 }
        return range.length
    }

    /// During composition `selectedRange` is not a reliable document caret, so
    /// a replacement counted from it misses the marked syllables and inserts
    /// the word again. The caret is the end of the marked range.
    private func rangeBeforeCaret(_ utf16: Int, client: IMKTextInput) -> NSRange {
        let marked = client.markedRange()
        let caret: Int
        if marked.location != NSNotFound, marked.length > 0 {
            caret = marked.location + marked.length
        } else {
            let selection = client.selectedRange()
            caret = selection.location == NSNotFound ? 0 : selection.location
        }
        let location = max(0, caret - utf16)
        let length = caret - location
        return NSRange(location: location, length: length)
    }

    private func marked(_ text: String) -> Any {
        guard !text.isEmpty else { return text }
        let string = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: (text as NSString).length)
        if let raw = mark(forStyle: kTSMHiliteSelectedRawText, at: range) {
            var attributes: [NSAttributedString.Key: Any] = [:]
            for (key, value) in raw {
                let name = (key.base as? String) ?? (key.base as? NSAttributedString.Key)?.rawValue
                if let name {
                    attributes[NSAttributedString.Key(name)] = value
                }
            }
            if !attributes.isEmpty {
                string.addAttributes(attributes, range: range)
            }
        }
        return string
    }
}

enum SharedTypoLog {
    static let store = TypoLog()
}

enum SharedTypingStatistics {
    static let store = TypingStatistics()
}

/// Menu toggles. Missing keys stay on, which is the default.
enum Preferences {
    static var layout: KeyboardLayout {
        get {
            UserDefaults.standard.string(forKey: "keyboardLayout")
                .flatMap(KeyboardLayout.init(rawValue:)) ?? .sebeol390
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "keyboardLayout") }
    }

    private static let autoSwitchKey = "autoSwitch"
    private static let correctTyposKey = "correctTypos"

    static var autoSwitch: Bool {
        get { stored(autoSwitchKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: autoSwitchKey) }
    }

    static var correctsTypos: Bool {
        get { stored(correctTyposKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: correctTyposKey) }
    }

    private static func stored(_ key: String, default fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }
}

enum SharedLexicon {
    static func editableDirectory() throws -> URL {
        let manager = FileManager.default
        let directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
            .appendingPathComponent("Sebeol390/Dictionaries", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundled = Bundle.main.resourceURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for filename in ["english-words.txt", "english-extra.txt", "korean-words.txt", "korean-valid.txt"] {
            let destination = directory.appendingPathComponent(filename)
            if !manager.fileExists(atPath: destination.path) {
                try manager.copyItem(at: bundled.appendingPathComponent(filename), to: destination)
            }
        }
        return directory
    }

    // IMK controller creation and menu callbacks are serialized on the main thread.
    nonisolated(unsafe) static var lexicon: Lexicon = {
        if let directory = try? editableDirectory(), let loaded = try? Lexicon.load(from: directory) {
            return loaded
        }
        if let url = Bundle.main.resourceURL {
            if let loaded = try? Lexicon.load(from: url) {
                return loaded
            }
        }
        let beside = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        if let loaded = try? Lexicon.load(from: beside) {
            return loaded
        }
        return Lexicon(english: [], korean: [], abbreviations: Lexicon.defaultAbbreviations, techStems: Lexicon.defaultTechStems)
    }()
}
