import UIKit

enum SuggestionLearning {
    static func allows(secureTextEntry: Bool, contentType: UITextContentType?) -> Bool {
        guard !secureTextEntry else { return false }
        guard contentType != .password, contentType != .newPassword else { return false }
        return true
    }
}

/// Touch keyboard uses standard Korean two-set and English QWERTY positions.
@MainActor
final class KeyboardView: UIView {
    static let keyHeight: CGFloat = 44
    static let rowGap: CGFloat = 11
    // 28pt phrase bar + five key rows + five gaps + 6pt top/bottom margins.
    static let preferredHeight: CGFloat = 315
    static let landscapeHeight: CGFloat = 240

    private let settingsDefaults: UserDefaults
    private var settingsTimer: Timer?
    private var rowHeights: [NSLayoutConstraint] = []
    private var horizontalConstraints: [NSLayoutConstraint] = []
    private(set) var oneHandedLayout: OneHandedLayout = .off
    /// Includes the 4pt key margins; the remaining side contains no controls.
    private(set) var keyAreaFrame: CGRect = .zero

    var onKey: ((Character) -> Void)?
    var onPhrase: ((String) -> Void)?
    var onSuggestion: ((WordSuggestionContext, String) -> Void)?
    var onLiteral: ((Character) -> Void)?
    var onDelete: (() -> Void)?
    /// One accelerated wave. The system keyboard deletes two word-units per wave.
    var onDeleteWord: (() -> Void)?
    /// Nil keeps repeating. False stops the hold after the deletion that emptied
    /// the field, which is what the system keyboard does.
    var backspaceHasMoreText: (() -> Bool)?
    var onToggle: (() -> Void)?
    /// Long-press of ※. The host re-reads the open word in the other language.
    var onReinterpretWord: (() -> Void)?
    var onNext: ((UIButton, UIEvent) -> Void)?
    var onAutoSwitch: (() -> Void)?
    var onCancelPendingDoubleSpace: (() -> Void)?
    /// Moves the insertion point by whole characters and lines; negative is
    /// left or up. Takes and returns the column kept across vertical steps.
    var onMoveCursor: ((CursorStep, Int?) -> Int?)?
    var showsInputModeSwitch = true { didSet { globe.isHidden = !showsInputModeSwitch; refreshPhrases() } }
    private let globe = UIButton(type: .system)
    private var languageButton: UIButton?
    private var shifted = false
    private var english = false
    private var hostEnglish = false
    private var symbols = false
    private let rows = UIStackView()
    private let phraseBar = UIStackView()
    private var phrases = UserDefaults.standard.stringArray(forKey: "quickPhrases") ?? []
    private var phraseSession: Session?
    private var editingPhraseIndex: Int?
    private var suggestionEngine: WordSuggestions?
    private var learnedWords: LearnedWords?
    private var suggestionContext: WordSuggestionContext?
    private var displayedSuggestionContext: WordSuggestionContext?
    private var suggestionTask: Task<Void, Never>?
    private var suggestions: [String] = []
    private var showingPhrases = false
    private var numberKeys: [(UIButton, Character, Character)] = []
    private var keys: [(UIButton, Character)] = []
    private let keyPreview = KeyPreviewView()
    private var alternates: [ObjectIdentifier: () -> HoldAlternate?] = [:]
    private var activeHolds: [ObjectIdentifier: (alternate: HoldAlternate, drag: CursorDrag)] = [:]
    private var suppressedAlternateActions: Set<ObjectIdentifier> = []
    private var backspaceRepeat = BackspaceRepeat()
    private var backspaceTimer: Timer?
    private var backspaceTouchDownDelete = false
    /// Tests replace the clock and turn the timer off, then call `advanceBackspaceRepeat()`.
    var backspaceClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var backspaceRepeatUsesTimer = true
    private weak var previewedButton: UIButton?
    private var previewText: [ObjectIdentifier: () -> String] = [:]

    override convenience init(frame: CGRect) {
        self.init(frame: frame, defaults: KeyboardSettings.defaults)
    }

    init(frame: CGRect, defaults: UserDefaults) {
        settingsDefaults = defaults
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        rows.axis = .vertical
        rows.spacing = Self.rowGap
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            rows.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6)
        ])
        phraseBar.spacing = 4
        phraseBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        rows.addArrangedSubview(phraseBar)
        refreshPhrases()
        let numbers = UIStackView()
        numbers.spacing = 4
        numbers.distribution = .fillEqually
        for (digit, symbol) in zip("1234567890", "!@#$%^&*()") {
            let button = makeButton("") { [weak self] in
                guard let self else { return }
                self.emitLiteral(self.shifted ? symbol : digit)
                if self.shifted { self.shifted = false; self.refresh() }
            }
            addPreview(to: button) { [weak self] in String(self?.shifted == true ? symbol : digit) }
            addAlternate(to: button, primary: digit, alternate: symbol)
            numberKeys.append((button, digit, symbol))
            numbers.addArrangedSubview(button)
        }
        rows.addArrangedSubview(numbers)
        for letters in ["qwertyuiop", "asdfghjkl", "zxcvbnm"] {
            let row = UIStackView()
            row.spacing = 4
            row.distribution = .fillEqually
            for character in letters {
                let button = makeButton("") { [weak self] in
                    guard let self else { return }
                    let output = self.output(character)
                    if self.symbols { self.emitLiteral(output) } else { self.emitKey(output) }
                    if self.shifted { self.shifted = false; self.refresh() }
                }
                button.titleLabel?.numberOfLines = 2
                button.titleLabel?.textAlignment = .center
                addPreview(to: button) { [weak button] in
                    button?.attributedTitle(for: .normal)?.string.components(separatedBy: "\n").first ?? ""
                }
                // Holding a letter types its Shift form (쌍자음·ㅒ·ㅖ or uppercase)
                // through the same composing path as a tap. Symbols have no Shift layer.
                button.accessibilityHint = "길게 눌러 Shift 글자 입력"
                addHold(to: button) { [weak self] in
                    guard let self, !self.symbols else { return nil }
                    let key = self.output(character, shifted: true)
                    return HoldAlternate(preview: self.english ? String(key) : self.koreanLabel(for: key)) { [weak self] in
                        guard let self else { return }
                        self.emitKey(key)
                        if self.shifted { self.shifted = false; self.refresh() }
                    }
                }
                keys.append((button, character))
                row.addArrangedSubview(button)
            }
            if letters.count < 10 {
                let inset = UIStackView()
                let leading: UIView
                let trailing: UIView
                if letters.count == 7 {
                    leading = makeButton("⇧", event: .touchDown) { [weak self] in self?.shifted.toggle(); self?.refresh() }
                    trailing = makeBackspaceButton()
                    inset.spacing = 14
                } else {
                    leading = UIView()
                    trailing = UIView()
                }
                inset.addArrangedSubview(leading)
                inset.addArrangedSubview(row)
                inset.addArrangedSubview(trailing)
                rows.addArrangedSubview(inset)
                leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
                if letters.count == 7 {
                    // Match the number / Q–P key width exactly at every screen size.
                    row.arrangedSubviews[0].widthAnchor.constraint(equalTo: numbers.arrangedSubviews[0].widthAnchor).isActive = true
                } else {
                    leading.widthAnchor.constraint(equalTo: inset.widthAnchor, multiplier: 0.05).isActive = true
                }
            } else {
                rows.addArrangedSubview(row)
            }
        }
        let controls = UIStackView()
        controls.spacing = 4
        controls.distribution = .fill
        style(globe)
        globe.setTitle("🌐", for: .normal)
        globe.accessibilityLabel = "다음 키보드"
        globe.addTarget(self, action: #selector(nextKeyboard(_:event:)), for: .allTouchEvents)
        globe.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let symbolKey = makeButton("※") { [weak self] in
            guard let self else { return }
            self.onCancelPendingDoubleSpace?()
            self.symbols.toggle(); self.refresh()
        }
        symbolKey.accessibilityLabel = "기호 자판 전환"
        symbolKey.accessibilityHint = "길게 눌러 방금 입력한 단어를 반대 자판으로 바꿉니다"
        addPreview(to: symbolKey) { "※" }
        // Tap still toggles the symbol layer. The hold re-reads the open word
        // and must not also run that tap.
        addHold(to: symbolKey) { [weak self] in
            HoldAlternate(preview: "한/영") { [weak self] in
                self?.reinterpretCurrentWord()
            }
        }
        controls.addArrangedSubview(symbolKey)
        let languageKey = makeButton("↔") { [weak self] in self?.toggleLanguage() }
        languageButton = languageKey
        languageKey.accessibilityLabel = "한영 전환 및 자동 변환 되돌리기"
        languageKey.accessibilityHint = "길게 눌러 자동 한영 전환 설정"
        controls.addArrangedSubview(languageKey)
        let hyphenKey = makeButton("-") { [weak self] in self?.emitLiteral("-") }
        addPreview(to: hyphenKey) { "-" }
        addAlternate(to: hyphenKey, primary: "-", alternate: "→")
        hyphenKey.accessibilityLabel = "하이픈 입력"
        controls.addArrangedSubview(hyphenKey)
        let space = makeButton("간격") { [weak self] in self?.emitKey(" ") }
        space.accessibilityHint = "길게 눌러 탭 입력, 길게 누른 채 끌어 커서 이동"
        addHold(to: space) { [weak self] in
            // Like the system keyboard, a hold that then slides moves the cursor
            // instead of typing: sideways by characters, up and down by lines.
            // Releasing without sliding still types a tab.
            // The phrase draft has no cursor, so there the hold stays tab-only.
            let moves = self?.phraseSession == nil && self?.onMoveCursor != nil
            return HoldAlternate(preview: "⇥", perform: { self?.emitLiteral("\t") },
                                 drag: moves ? { self?.onMoveCursor?($0, $1) } : nil)
        }
        space.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        controls.addArrangedSubview(space)
        for punctuation: Character in [".", "?"] {
            let punctuationKey = makeButton(String(punctuation)) { [weak self] in
                guard let self else { return }
                self.emitLiteral(punctuation)
                if self.shifted { self.shifted = false; self.refresh() }
            }
            addPreview(to: punctuationKey) { String(punctuation) }
            addAlternate(to: punctuationKey, primary: punctuation, alternate: punctuation == "." ? "," : "!")
            controls.addArrangedSubview(punctuationKey)
        }
        controls.addArrangedSubview(makeButton("↵") { [weak self] in self?.emitKey("\n") })
        rows.addArrangedSubview(controls)
        for case let button as UIButton in controls.arrangedSubviews {
            button.titleLabel?.font = .systemFont(ofSize: 16)
            if button !== space {
                button.widthAnchor.constraint(equalTo: numbers.arrangedSubviews[0].widthAnchor).isActive = true
            }
        }
        symbolKey.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        for row in rows.arrangedSubviews.dropFirst() {
            let height = row.heightAnchor.constraint(equalToConstant: Self.keyHeight)
            height.isActive = true
            rowHeights.append(height)
        }
        reloadSettings()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        keyPreview.isHidden = true
        addSubview(keyPreview)
        refresh()
    }

    @objc private func defaultsChanged() { reloadSettings() }

    func reloadSettings() {
        let value = KeyboardSettings.oneHandedLayout(in: settingsDefaults)
        guard horizontalConstraints.isEmpty || value != oneHandedLayout else { return }
        oneHandedLayout = value
        NSLayoutConstraint.deactivate(horizontalConstraints)
        horizontalConstraints = [
            rows.widthAnchor.constraint(equalTo: widthAnchor,
                                        multiplier: value == .off ? 1 : 0.85, constant: -8),
            value == .right
                ? rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
                : rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        ]
        NSLayoutConstraint.activate(horizontalConstraints)
        dismissPreview()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        // Shrink evenly in a shorter host (including landscape); never stretch keys.
        let available = max(0, bounds.height - safeAreaInsets.bottom - 40)
        let scale = min(1, available / (5 * (Self.keyHeight + Self.rowGap)))
        rows.spacing = Self.rowGap * scale
        for height in rowHeights { height.constant = Self.keyHeight * scale }
        super.layoutSubviews()
        let width = bounds.width * (oneHandedLayout == .off ? 1 : 0.85)
        keyAreaFrame = CGRect(x: oneHandedLayout == .right ? bounds.width - width : 0,
                              y: 0, width: width, height: bounds.height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(mode: Language, automatic: Bool) {
        languageButton?.menu = UIMenu(children: [UIAction(title: "자동 한영 전환", state: automatic ? .on : .off) { [weak self] _ in
            self?.onAutoSwitch?()
        }])
        hostEnglish = mode == .english
        if phraseSession == nil { english = hostEnglish }
        refresh()
    }

    func configureSuggestions(lexicon: Lexicon, learned: LearnedWords? = nil) {
        suggestionEngine = WordSuggestions(lexicon: lexicon)
        learnedWords = learned
    }

    /// Personal suggestions are omitted when the focused field must not be learned.
    func setLearnedWords(_ learned: LearnedWords?) {
        guard learned !== learnedWords else { return }
        learnedWords = learned
        suggestionTask?.cancel()
        suggestionContext = nil
        displayedSuggestionContext = nil
        suggestions = []
        showingPhrases = false
        refreshPhrases()
    }

    func updateSuggestionContext(_ context: WordSuggestionContext?) {
        guard context != suggestionContext else { return }
        suggestionTask?.cancel()
        suggestionContext = context
        if context == nil {
            suggestions = []
            displayedSuggestionContext = nil
            showingPhrases = false
        }
        refreshPhrases()
        guard let context, let engine = suggestionEngine else { return }
        let learned = learnedWords
        suggestionTask = Task { [weak self] in
            // Coalesce rapid taps and keep dictionary work off the UI thread.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            let candidates = await Task.detached(priority: .userInitiated) {
                if context.predictsNextWord {
                    return learned?.nextWords(after: context.before) ?? []
                }
                let personal = learned?.prefixMatches(for: context.word) ?? []
                return engine.candidates(for: context.word, promoting: personal)
            }.value
            guard !Task.isCancelled, let self, self.suggestionContext == context else { return }
            self.suggestions = candidates
            self.displayedSuggestionContext = context
            self.refreshPhrases()
        }
    }

    private func emitKey(_ key: Character) {
        guard let phraseSession else { onKey?(key); return }
        if key == "\n" { savePhrase(); return }
        _ = phraseSession.input(LayoutDubeol.atom(for: key))
        refreshPhrases()
    }

    private func emitLiteral(_ key: Character) {
        guard let phraseSession else { onLiteral?(key); return }
        _ = phraseSession.input(KeyAtom(english: key, korean: .character(key)))
        refreshPhrases()
    }

    private func emitDelete() {
        guard let phraseSession else { onDelete?(); return }
        _ = phraseSession.backspace()
        refreshPhrases()
    }

    /// Held backspace is not an alternate-character hold. Those emit once on
    /// release. This key deletes on contact and keeps deleting until the finger
    /// lifts, so a tap is exactly one ordinary deletion and release adds none.
    private func makeBackspaceButton() -> UIButton {
        let backspace = makeButton("⌫", event: .touchDown) { [weak self] in
            self?.beginBackspaceHold()
        }
        backspace.accessibilityLabel = "삭제"
        backspace.accessibilityHint = "길게 누르면 글자를 반복해서 지우고, 더 오래 누르면 단어 단위로 지웁니다"
        backspace.addTarget(self, action: #selector(endBackspaceHold), for: .touchUpInside)
        backspace.addTarget(self, action: #selector(cancelBackspaceTouch), for: [.touchUpOutside, .touchCancel])
        return backspace
    }

    private func beginBackspaceHold() {
        guard !backspaceTouchDownDelete else { return }
        backspaceTouchDownDelete = true
        let started = backspaceClock()
        emitDelete()
        guard backspaceShouldContinue() else { return }
        backspaceRepeat.begin(at: started)
        scheduleBackspaceTimer()
    }

    /// A control activation without a touch-down (VoiceOver) still deletes once.
    /// A real press already deleted on contact, so lifting must not delete again.
    @objc private func endBackspaceHold() {
        let fromTouch = backspaceTouchDownDelete
        cancelBackspaceHold()
        if !fromTouch { emitDelete() }
    }

    @objc private func cancelBackspaceTouch() {
        cancelBackspaceHold()
    }

    func cancelBackspaceHold() {
        backspaceTouchDownDelete = false
        stopBackspaceRepeat()
    }

    private func stopBackspaceRepeat() {
        backspaceRepeat.end()
        backspaceTimer?.invalidate()
        backspaceTimer = nil
    }

    func backspaceNextDeadline() -> TimeInterval? {
        backspaceRepeat.nextDeadline()
    }

    func advanceBackspaceRepeat() {
        let actions = backspaceRepeat.dueActions(at: backspaceClock())
        for action in actions {
            performBackspaceRepeatAction(action)
            if !backspaceShouldContinue() {
                // The finger may still be down. Stopping the timer must not
                // look like a touch-up, or release would delete once more.
                stopBackspaceRepeat()
                return
            }
        }
        scheduleBackspaceTimer()
    }

    func performBackspaceRepeatAction(_ action: BackspaceRepeat.Action) {
        switch action {
        case .character:
            emitDelete()
        case .word:
            emitDeleteWord()
        }
    }

    private func emitDeleteWord() {
        if let phraseSession {
            if phraseSession.preedit.isEmpty {
                let pieces = WordDeletion.units(in: phraseSession.document, count: BackspaceRepeat.wordsPerTick)
                let suffixCount = pieces.reduce(0) { $0 + $1.count }
                let goal = max(0, phraseSession.document.count - suffixCount)
                var steps = 0
                while phraseSession.document.count > goal, steps < suffixCount * 4 + 2 {
                    steps += 1
                    if !phraseSession.preedit.isEmpty {
                        _ = phraseSession.backspace()
                        break
                    }
                    let before = phraseSession.document
                    _ = phraseSession.backspace()
                    if phraseSession.document == before { break }
                }
            } else {
                // An open syllable still loses one jamo, same as a tap.
                _ = phraseSession.backspace()
            }
            refreshPhrases()
            return
        }
        if let onDeleteWord {
            onDeleteWord()
        } else {
            onDelete?()
        }
    }

    private func backspaceShouldContinue() -> Bool {
        if let phraseSession { return !phraseSession.document.isEmpty }
        return backspaceHasMoreText?() ?? true
    }

    private func scheduleBackspaceTimer() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        guard backspaceRepeatUsesTimer, let deadline = backspaceRepeat.nextDeadline() else { return }
        let delay = max(0, deadline - backspaceClock())
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceBackspaceRepeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        backspaceTimer = timer
    }

    private func toggleLanguage() {
        guard let phraseSession else { onToggle?(); return }
        english.toggle()
        _ = phraseSession.forceMode(english ? .english : .korean)
        refresh()
    }

    /// ※ long-press. Phrase entry has its own session; the field is the host's.
    private func reinterpretCurrentWord() {
        onCancelPendingDoubleSpace?()
        if let phraseSession {
            _ = phraseSession.convertOpenWord()
            english = phraseSession.mode == .english
            refresh()
            refreshPhrases()
            return
        }
        onReinterpretWord?()
    }

    private func beginPhrase(at index: Int? = nil) {
        onCancelPendingDoubleSpace?()
        editingPhraseIndex = index
        let editor = Session(lexicon: Lexicon(english: [], korean: []), autoSwitch: false, mode: english ? .english : .korean, layout: .dubeol)
        editor.correctsTypos = false
        if let index {
            for character in phrases[index] { _ = editor.input(KeyAtom(english: character, korean: .character(character))) }
        }
        phraseSession = editor
        refreshPhrases()
    }

    private func savePhrase() {
        guard let text = phraseSession?.document, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = editingPhraseIndex { phrases[index] = text }
        else { phrases.append(text) }
        UserDefaults.standard.set(phrases, forKey: "quickPhrases")
        phraseSession = nil
        editingPhraseIndex = nil
        english = hostEnglish
        refresh()
        refreshPhrases()
    }

    private func refreshPhrases() {
        for view in phraseBar.arrangedSubviews { phraseBar.removeArrangedSubview(view); view.removeFromSuperview() }
        if showsInputModeSwitch { phraseBar.addArrangedSubview(globe) }
        if let phraseSession {
            let draft = UILabel()
            draft.font = .systemFont(ofSize: 14)
            draft.textColor = .label
            draft.text = phraseSession.document.isEmpty ? "저장할 문구를 입력하세요" : phraseSession.document
            draft.lineBreakMode = .byTruncatingHead
            draft.accessibilityIdentifier = "phraseDraft"
            phraseBar.addArrangedSubview(draft)
            let save = makeButton("저장") { [weak self] in self?.savePhrase() }
            save.accessibilityIdentifier = "savePhrase"
            save.isEnabled = !phraseSession.document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            phraseBar.addArrangedSubview(save)
            phraseBar.addArrangedSubview(makeButton("취소") { [weak self] in
                guard let self else { return }
                self.phraseSession = nil; self.editingPhraseIndex = nil
                self.english = self.hostEnglish; self.refresh(); self.refreshPhrases()
            })
            for button in phraseBar.arrangedSubviews.compactMap({ $0 as? UIButton }) where button !== globe {
                button.titleLabel?.font = .systemFont(ofSize: 13)
                button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            }
            return
        }
        if !suggestions.isEmpty, let context = displayedSuggestionContext {
            let toggle = makeButton(showingPhrases ? "추천" : "문구") { [weak self] in
                guard let self else { return }
                self.onCancelPendingDoubleSpace?()
                self.showingPhrases.toggle()
                self.refreshPhrases()
            }
            toggle.titleLabel?.font = .systemFont(ofSize: 13)
            toggle.accessibilityIdentifier = "toggleSuggestions"
            toggle.accessibilityLabel = showingPhrases ? "단어 제안 보기" : "자주 쓰는 문구 보기"
            toggle.widthAnchor.constraint(equalToConstant: 40).isActive = true
            phraseBar.addArrangedSubview(toggle)
            if !showingPhrases {
                let candidates = UIStackView()
                candidates.spacing = 4
                candidates.distribution = .fillEqually
                for suggestion in suggestions {
                    let button = makeButton(suggestion) { [weak self] in
                        guard let self, self.suggestionContext == context else { return }
                        self.onSuggestion?(context, suggestion)
                    }
                    button.titleLabel?.font = .systemFont(ofSize: 14)
                    button.titleLabel?.lineBreakMode = .byTruncatingTail
                    button.titleLabel?.adjustsFontSizeToFitWidth = true
                    button.titleLabel?.minimumScaleFactor = 0.75
                    button.accessibilityIdentifier = "wordSuggestion"
                    button.accessibilityLabel = suggestion
                    button.accessibilityHint = context.predictsNextWord ? "이 단어를 이어서 입력합니다" : "현재 단어를 이 후보로 바꿉니다"
                    button.isEnabled = context == suggestionContext
                    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    candidates.addArrangedSubview(button)
                }
                phraseBar.addArrangedSubview(candidates)
                return
            }
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let items = UIStackView()
        items.spacing = 6
        items.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(items)
        NSLayoutConstraint.activate([
            items.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            items.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            items.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            items.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            items.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        if phrases.isEmpty {
            let hint = UILabel()
            hint.text = "＋ 자주 쓰는 문구 등록"
            hint.textColor = .secondaryLabel
            hint.font = .systemFont(ofSize: 13)
            items.addArrangedSubview(hint)
        }
        for (index, phrase) in phrases.enumerated() {
            let button = makeButton(String(phrase.prefix(18))) { [weak self] in self?.onPhrase?(phrase) }
            button.titleLabel?.font = .systemFont(ofSize: 13)
            button.accessibilityLabel = phrase
            button.accessibilityHint = "눌러 입력, 길게 눌러 수정 또는 삭제"
            button.menu = UIMenu(children: [
                UIAction(title: "수정", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.beginPhrase(at: index) },
                UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    self.phrases.remove(at: index)
                    UserDefaults.standard.set(self.phrases, forKey: "quickPhrases")
                    self.refreshPhrases()
                }
            ])
            items.addArrangedSubview(button)
        }
        phraseBar.addArrangedSubview(scroll)
        let add = makeButton("＋") { [weak self] in self?.beginPhrase() }
        add.accessibilityLabel = "문구 등록"
        add.widthAnchor.constraint(equalToConstant: 32).isActive = true
        phraseBar.addArrangedSubview(add)
    }

    @objc private func nextKeyboard(_ sender: UIButton, event: UIEvent) { onNext?(sender, event) }

    private func output(_ character: Character) -> Character {
        output(character, shifted: shifted)
    }

    private func output(_ character: Character, shifted: Bool) -> Character {
        if symbols {
            let positions = Array("1234567890qwertyuiopasdfghjkl;zxcvbnm,./")
            let values = Array("1234567890-/:;()₩&@~,+!'\"[]{}+=_*%<>\\|~`#")
            if let index = positions.firstIndex(of: character), index < values.count { return values[index] }
        }
        guard shifted else { return character }
        let base = Array("1234567890;,./")
        let upper = Array("!@#$%^&*():<>?")
        if let index = base.firstIndex(of: character) { return upper[index] }
        return Character(String(character).uppercased())
    }

    private func refresh() {
        UIView.performWithoutAnimation { refreshKeyLabels() }
    }

    private func refreshKeyLabels() {
        for (button, digit, symbol) in numberKeys {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
            let label = NSAttributedString(string: String(digit) + " " + String(symbol), attributes: attributes)
            button.setAttributedTitle(label, for: .normal)
            button.accessibilityLabel = "숫자 \(digit), Shift \(symbol), 현재 \(shifted ? symbol : digit)"
        }
        for (button, character) in keys {
            let key = output(character)
            let korean = koreanLabel(for: key)
            let title = english || symbols ? String(key) : korean
            let secondary = english ? korean : String(key)
            let stacked = !symbols && secondary != title
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: stacked ? 17 : 21, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
            let label = NSAttributedString(string: stacked ? title + "\n" + secondary : title, attributes: attributes)
            button.setAttributedTitle(label, for: .normal)
            button.accessibilityLabel = symbols ? title : "한글 \(korean), 영문 \(key), 현재 \(title)"
        }
    }

    private func koreanLabel(for key: Character) -> String {
        switch LayoutDubeol.atom(for: key).korean {
        case .jamo(let jamo): return String(jamo.compat)
        case .character(let value): return String(value)
        }
    }

    private func addPreview(to button: UIButton, text: @escaping () -> String) {
        previewText[ObjectIdentifier(button)] = text
        button.addTarget(self, action: #selector(showPreview(_:)), for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(hidePreview(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    @objc private func showPreview(_ button: UIButton) {
        guard let text = previewText[ObjectIdentifier(button)]?() else { return }
        showPreview(button, text: text)
    }

    private func showPreview(_ button: UIButton, text: String) {
        layoutIfNeeded()
        let key = button.convert(button.bounds, to: self)
        let width = min(bounds.width, max(60, key.width + 24))
        let top = max(0, key.minY - 54)
        let x = max(0, min(bounds.width - width, key.midX - width / 2))
        keyPreview.layer.removeAllAnimations()
        keyPreview.transform = .identity
        keyPreview.frame = CGRect(x: x, y: top, width: width, height: key.maxY - top)
        keyPreview.configure(text: text, keyFrame: key.offsetBy(dx: -x, dy: -top))
        previewedButton = button
        bringSubviewToFront(keyPreview)
        keyPreview.isHidden = false
        if !UIAccessibility.isReduceMotionEnabled {
            keyPreview.alpha = 0
            keyPreview.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.keyPreview.alpha = 1
                self.keyPreview.transform = .identity
            }
        } else { keyPreview.alpha = 1 }
    }

    private func addAlternate(to button: UIButton, primary: Character, alternate: Character) {
        button.accessibilityHint = "길게 눌러 \(alternate) 입력"
        addHold(to: button) { [weak self] in
            HoldAlternate(preview: String(alternate)) {
                guard let self else { return }
                self.emitLiteral(alternate)
                if self.shifted { self.shifted = false; self.refresh() }
            }
        }
    }

    /// Every long-press key shares one path: the alternate is resolved when the
    /// hold begins, the button's tap action is suppressed, and release emits it.
    /// A resolver returning nil leaves the hold as an ordinary tap.
    private func addHold(to button: UIButton, resolve: @escaping () -> HoldAlternate?) {
        alternates[ObjectIdentifier(button)] = resolve
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdAlternate(_:)))
        hold.minimumPressDuration = 0.4
        hold.cancelsTouchesInView = false
        button.addGestureRecognizer(hold)
        // A drag can end outside the key, where .touchUpInside never fires to
        // consume the suppression; clear it so the next tap is not swallowed.
        button.addTarget(self, action: #selector(clearSuppressedAlternateAction(_:)), for: [.touchUpOutside, .touchCancel])
    }

    @objc private func clearSuppressedAlternateAction(_ button: UIButton) {
        suppressedAlternateActions.remove(ObjectIdentifier(button))
    }

    @objc private func holdAlternate(_ hold: UILongPressGestureRecognizer) {
        guard let button = hold.view as? UIButton else { return }
        let id = ObjectIdentifier(button)
        switch hold.state {
        case .began:
            guard let alternate = alternates[id]?() else { return }
            activeHolds[id] = (alternate, CursorDrag(start: hold.location(in: self)))
            suppressedAlternateActions.insert(id)
            if previewedButton === button { showPreview(button, text: alternate.preview) }
        case .changed:
            guard var active = activeHolds[id], let move = active.alternate.drag else { return }
            let wasDragging = active.drag.isDragging
            let delta = active.drag.update(to: hold.location(in: self))
            if !wasDragging, active.drag.isDragging { dismissPreview() }
            if !delta.isZero { active.drag.goalColumn = move(delta, active.drag.goalColumn) }
            activeHolds[id] = active
        case .ended:
            guard let active = activeHolds.removeValue(forKey: id) else { return }
            dismissPreview()
            if !active.drag.isDragging { active.alternate.perform() }
        case .cancelled, .failed:
            activeHolds.removeValue(forKey: id)
            suppressedAlternateActions.remove(id)
        default:
            break
        }
    }

    @objc private func hidePreview(_ button: UIButton) {
        guard previewedButton === button else { return }
        dismissPreview()
    }

    private func dismissPreview() {
        keyPreview.layer.removeAllAnimations()
        keyPreview.isHidden = true
        keyPreview.transform = .identity
        previewedButton = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        settingsTimer?.invalidate()
        settingsTimer = nil
        reloadSettings()
        if window != nil {
            // didChangeNotification is process-local. Re-read while visible so changes
            // from the containing app are also picked up across processes.
            settingsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadSettings() }
            }
        }
        if window == nil {
            dismissPreview()
            cancelBackspaceHold()
        }
    }

    private func style(_ button: UIButton) {
        button.backgroundColor = .tertiarySystemBackground
        button.layer.cornerRadius = 5
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.setTitleColor(.label, for: .normal)
    }

    private func makeButton(_ title: String, event: UIControl.Event = .touchUpInside, action: @escaping () -> Void) -> UIButton {
        let button = ImmediateKeyboardButton(type: .custom)
        style(button)
        button.setTitle(title, for: .normal)
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button, !self.consumeSuppressedAlternateAction(for: button) else { return }
            action()
        }, for: event)
        return button
    }

    private func consumeSuppressedAlternateAction(for button: UIButton) -> Bool {
        suppressedAlternateActions.remove(ObjectIdentifier(button)) != nil
    }
}

/// Cadence of a held backspace on the system iPhone keyboard.
///
/// One deletion happens on contact, outside this schedule. Then a 500 ms pause,
/// twenty character deletions every 100 ms, then a word wave every 350 ms.
/// The first wave is one character-interval after the last character, and later
/// waves are 350 ms apart. Releasing makes `dueActions` empty.
///
/// Those intervals match the iOS 26 software keyboard: character deletion does
/// not speed up, and each word wave removes two word-units about 350 ms apart.
struct BackspaceRepeat: Equatable {
    static let initialDelay: TimeInterval = 0.5
    static let characterInterval: TimeInterval = 0.1
    static let characterRepeatCount = 20
    static let wordInterval: TimeInterval = 0.35
    /// The system keyboard removes two word-units on each wave.
    static let wordsPerTick = 2

    enum Action: Equatable {
        case character
        case word
    }

    private(set) var isPressing = false
    private var start: TimeInterval = 0
    private var ticks = 0

    mutating func begin(at now: TimeInterval) {
        isPressing = true
        start = now
        ticks = 0
    }

    mutating func end() {
        isPressing = false
    }

    func nextDeadline() -> TimeInterval? {
        guard isPressing else { return nil }
        return time(of: ticks)
    }

    mutating func dueActions(at now: TimeInterval) -> [Action] {
        guard isPressing else { return [] }
        var actions: [Action] = []
        var steps = 0
        while let deadline = nextDeadline(), deadline <= now, steps < 10_000 {
            steps += 1
            if ticks < Self.characterRepeatCount {
                actions.append(.character)
            } else {
                actions.append(.word)
            }
            ticks += 1
        }
        return actions
    }

    private func time(of tick: Int) -> TimeInterval {
        if tick < Self.characterRepeatCount {
            return start + Self.initialDelay + TimeInterval(tick) * Self.characterInterval
        }
        let wordIndex = tick - Self.characterRepeatCount
        let wordStart = start + Self.initialDelay + TimeInterval(Self.characterRepeatCount) * Self.characterInterval
        return wordStart + TimeInterval(wordIndex) * Self.wordInterval
    }
}

/// Backward word-units, matching the system keyboard's held-delete waves.
///
/// A unit is the trailing whitespace run plus the word before it. Inside a
/// word, it is just that word. Hyphens are boundaries and are deleted with the
/// word they follow. Other punctuation stays attached to the word.
enum WordDeletion {
    struct Plan: Equatable {
        /// One ordinary backspace. Used for an open syllable, a selection,
        /// or a host that is not showing the text before the caret.
        var single: Bool
        var sessionBackspaces: Int
        var hostBackspaces: Int

        static let one = Plan(single: true, sessionBackspaces: 0, hostBackspaces: 0)
    }

    static func plan(contextBefore: String?, sessionDocument: String, composing: Bool, selection: Bool) -> Plan {
        if composing || selection { return .one }
        guard let contextBefore else { return .one }
        let suffix = units(in: contextBefore, count: BackspaceRepeat.wordsPerTick).reversed().joined()
        guard !suffix.isEmpty, contextBefore.hasSuffix(suffix) else { return .one }
        let owned = sharedSuffixCount(sessionDocument, suffix)
        // The session is not a suffix of the visible word. One backspace keeps
        // the two buffers from being edited in opposite directions.
        if !sessionDocument.isEmpty, owned == 0 { return .one }
        return Plan(single: false, sessionBackspaces: owned, hostBackspaces: suffix.count - owned)
    }

    static func units(in text: String, count: Int) -> [String] {
        var remaining = text
        var result: [String] = []
        for _ in 0..<count {
            let piece = unit(in: remaining)
            if piece.isEmpty { break }
            result.append(piece)
            remaining.removeLast(piece.count)
        }
        return result
    }

    static func unit(in text: String) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else { return "" }
        var index = characters.count
        if characters[index - 1].isWhitespace {
            while index > 0, characters[index - 1].isWhitespace { index -= 1 }
        }
        if index > 0, isHyphen(characters[index - 1]) {
            while index > 0, isHyphen(characters[index - 1]) { index -= 1 }
        }
        while index > 0, isWordBody(characters[index - 1]) { index -= 1 }
        return String(characters[index...])
    }

    static func sharedSuffixCount(_ text: String, _ suffix: String) -> Int {
        let left = Array(text)
        let right = Array(suffix)
        var count = 0
        while count < left.count, count < right.count, left[left.count - 1 - count] == right[right.count - 1 - count] {
            count += 1
        }
        return count
    }

    private static func isHyphen(_ character: Character) -> Bool {
        switch character {
        case "-", "‐", "‑", "–", "—":
            return true
        default:
            return false
        }
    }

    private static func isWordBody(_ character: Character) -> Bool {
        !character.isWhitespace && !isHyphen(character)
    }
}

/// What a held key emits on release, and the glyph its preview shows meanwhile.
/// A key with `drag` turns a slide during the hold into cursor steps, and then
/// releasing emits nothing. The handler returns the column to keep for the
/// next vertical step of the same drag.
private struct HoldAlternate {
    let preview: String
    let perform: () -> Void
    var drag: ((CursorStep, Int?) -> Int?)? = nil
}

/// Cursor movement since the previous drag update. Negative is left or up.
struct CursorStep: Equatable {
    var characters = 0
    var lines = 0
    var isZero: Bool { characters == 0 && lines == 0 }
}

/// Converts a held finger's travel into whole cursor steps: characters
/// sideways and lines vertically. A line step needs more travel than a
/// character so a sideways slide does not drift across lines.
struct CursorDrag {
    static let stepWidth: CGFloat = 10
    static let stepHeight: CGFloat = 24
    let start: CGPoint
    private(set) var steps = CursorStep()
    private(set) var isDragging = false
    /// The column a run of vertical steps aims for, reset by a sideways step.
    var goalColumn: Int?

    init(start: CGPoint) { self.start = start }

    /// Returns how far to move since the previous update.
    mutating func update(to point: CGPoint) -> CursorStep {
        let target = CursorStep(characters: Int((point.x - start.x) / Self.stepWidth),
                                lines: Int((point.y - start.y) / Self.stepHeight))
        let delta = CursorStep(characters: target.characters - steps.characters,
                               lines: target.lines - steps.lines)
        steps = target
        if !delta.isZero { isDragging = true }
        return delta
    }
}

/// Where a space-drag step puts the caret, computed from the text known on
/// either side of it (`documentContextBeforeInput`/`AfterInput` in the
/// keyboard extension, the whole text in the app editor).
///
/// Sideways steps move by whole characters. A vertical step goes to the
/// previous or next hard line (soft wrapping is not visible to a keyboard)
/// and lands on the boundary whose visual column is nearest to the caret's
/// column on its current line. Wide characters (Hangul, CJK, emoji) count as
/// two columns and a tab as four. Vertical steps stop when the context does
/// not reach the adjacent line.
struct CursorMotion: Equatable {
    /// Signed caret move in UTF-16 units, as `adjustTextPosition` expects.
    var utf16Offset: Int
    /// Column for the next vertical step; nil after a sideways step.
    var goalColumn: Int?

    /// `extendsBeyondContext` moves one UTF-16 unit per sideways step the
    /// context cannot cover, for a proxy that hides the rest of the text.
    static func resolve(before: String, after: String, step: CursorStep, goalColumn: Int? = nil,
                        extendsBeyondContext: Bool = false) -> CursorMotion {
        let text = Array(before) + Array(after)
        let caret = before.count
        var index = caret
        var goal = goalColumn
        for _ in 0..<abs(step.lines) {
            let start = lineStart(text, before: index)
            let column = goal ?? width(text[start..<index])
            let target: Int?
            if step.lines < 0 {
                // The line above ends at the newline just before this line.
                target = start > 0
                    ? nearest(column, in: text, from: lineStart(text, before: start - 1), to: start - 1)
                    : nil
            } else {
                let end = lineEnd(text, from: index)
                target = end < text.count
                    ? nearest(column, in: text, from: end + 1, to: lineEnd(text, from: end + 1))
                    : nil
            }
            guard let target else { break }
            index = target
            goal = column
        }
        var overflow = 0
        if step.characters != 0 {
            let moved = min(max(index + step.characters, 0), text.count)
            overflow = step.characters - (moved - index)
            index = moved
            goal = nil
        }
        let units = index >= caret
            ? text[caret..<index].reduce(0) { $0 + $1.utf16.count }
            : -text[index..<caret].reduce(0) { $0 + $1.utf16.count }
        return CursorMotion(utf16Offset: units + (extendsBeyondContext ? overflow : 0), goalColumn: goal)
    }

    private static func lineStart(_ text: [Character], before index: Int) -> Int {
        var start = index
        while start > 0, !text[start - 1].isNewline { start -= 1 }
        return start
    }

    private static func lineEnd(_ text: [Character], from index: Int) -> Int {
        var end = index
        while end < text.count, !text[end].isNewline { end += 1 }
        return end
    }

    /// The boundary in `start...end` closest to `column`; ties go left.
    private static func nearest(_ column: Int, in text: [Character], from start: Int, to end: Int) -> Int {
        var best = start
        var bestDistance = column
        var position = 0
        for index in start..<end {
            position += width(text[index])
            let distance = abs(position - column)
            if distance < bestDistance {
                best = index + 1
                bestDistance = distance
            }
            if position >= column { break }
        }
        return best
    }

    private static func width(_ characters: ArraySlice<Character>) -> Int {
        characters.reduce(0) { $0 + width($1) }
    }

    static func width(_ character: Character) -> Int {
        if character == "\t" { return 4 }
        guard let first = character.unicodeScalars.first else { return 0 }
        if character.unicodeScalars.count > 1, character.unicodeScalars.contains(where: \.properties.isEmoji),
           character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x200D }) {
            return 2
        }
        if first.properties.isEmojiPresentation { return 2 }
        switch first.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

/// Keyboard feedback must follow touch-down without UIButton.system's title fades.
@MainActor
private final class ImmediateKeyboardButton: UIButton {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .secondarySystemFill : .tertiarySystemBackground }
    }
}

/// A noninteractive balloon drawn inside the keyboard's permitted bounds.
@MainActor
private final class KeyPreviewView: UIView {
    private let shape = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        accessibilityIdentifier = "keyPreview"
        layer.addSublayer(shape)
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.25
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: 2)
        label.font = .systemFont(ofSize: 32, weight: .medium)
        label.textAlignment = .center
        label.textColor = .label
        label.accessibilityIdentifier = "keyPreviewText"
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, keyFrame: CGRect) {
        let headHeight = min(54, bounds.height)
        let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: bounds.width, height: headHeight), cornerRadius: 10)
        let stem = CGRect(x: keyFrame.minX, y: max(0, headHeight - 14), width: keyFrame.width, height: bounds.height - max(0, headHeight - 14))
        path.append(UIBezierPath(roundedRect: stem, cornerRadius: 5))
        shape.frame = bounds
        shape.path = path.cgPath
        shape.shadowPath = path.cgPath
        shape.fillColor = UIColor.tertiarySystemBackground.resolvedColor(with: traitCollection).cgColor
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headHeight)
        label.text = text
    }
}

