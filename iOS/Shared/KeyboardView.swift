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
    static let preferredHeight: CGFloat = 280

    var onKey: ((Character) -> Void)?
    var onPhrase: ((String) -> Void)?
    var onSuggestion: ((WordSuggestionContext, String) -> Void)?
    var onLiteral: ((Character) -> Void)?
    var onDelete: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: ((UIButton, UIEvent) -> Void)?
    var onAutoSwitch: (() -> Void)?
    var onCancelPendingDoubleSpace: (() -> Void)?
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
    private var alternates: [ObjectIdentifier: Character] = [:]
    private weak var previewedButton: UIButton?
    private var previewText: [ObjectIdentifier: () -> String] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        rows.axis = .vertical
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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
                keys.append((button, character))
                row.addArrangedSubview(button)
            }
            if letters.count < 10 {
                let inset = UIStackView()
                let leading: UIView
                let trailing: UIView
                if letters.count == 7 {
                    leading = makeButton("⇧", event: .touchDown) { [weak self] in self?.shifted.toggle(); self?.refresh() }
                    trailing = makeButton("⌫") { [weak self] in self?.emitDelete() }
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
        let symbolKey = makeButton("#") { [weak self] in
            guard let self else { return }
            self.onCancelPendingDoubleSpace?()
            self.symbols.toggle(); self.refresh()
        }
        symbolKey.accessibilityLabel = "기호 자판 전환"
        controls.addArrangedSubview(symbolKey)
        let languageKey = makeButton("↔") { [weak self] in self?.toggleLanguage() }
        languageButton = languageKey
        languageKey.accessibilityLabel = "한영 전환 및 자동 변환 되돌리기"
        languageKey.accessibilityHint = "길게 눌러 자동 한영 전환 설정"
        controls.addArrangedSubview(languageKey)
        let arrowKey = makeButton("→") { [weak self] in self?.emitLiteral("→") }
        addPreview(to: arrowKey) { "→" }
        arrowKey.accessibilityLabel = "오른쪽 화살표 입력"
        controls.addArrangedSubview(arrowKey)
        let space = makeButton("간격") { [weak self] in self?.emitKey(" ") }
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
        for row in rows.arrangedSubviews.dropFirst() {
            row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        }
        keyPreview.isHidden = true
        addSubview(keyPreview)
        refresh()
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

    private func toggleLanguage() {
        guard let phraseSession else { onToggle?(); return }
        english.toggle()
        _ = phraseSession.forceMode(english ? .english : .korean)
        refresh()
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
        if symbols {
            let positions = Array("1234567890qwertyuiopasdfghjkl;zxcvbnm,./")
            let values = Array("1234567890-/:;()₩&@.,?!'\"[]{}+=_*%<>\\|~`#")
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
            let label = NSMutableAttributedString(string: String(digit), attributes: [
                .font: UIFont.systemFont(ofSize: shifted ? 16 : 21, weight: shifted ? .regular : .semibold),
                .foregroundColor: shifted ? UIColor.secondaryLabel : UIColor.label
            ])
            label.append(NSAttributedString(string: " " + String(symbol), attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: shifted ? .semibold : .regular),
                .foregroundColor: shifted ? UIColor.label : UIColor.secondaryLabel
            ]))
            button.setAttributedTitle(label, for: .normal)
            button.accessibilityLabel = "숫자 \(digit), Shift \(symbol), 현재 \(shifted ? symbol : digit)"
        }
        for (button, character) in keys {
            let key = output(character)
            let title: String
            let korean: String
            switch LayoutDubeol.atom(for: key).korean {
            case .jamo(let jamo): korean = String(jamo.compat)
            case .character(let value): korean = String(value)
            }
            title = english || symbols ? String(key) : korean
            let secondary = english ? korean : String(key)
            let label = NSMutableAttributedString(string: title, attributes: [
                .font: UIFont.systemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: UIColor.label
            ])
            if !symbols && secondary != title {
                label.append(NSAttributedString(string: "\n" + secondary, attributes: [
                    .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]))
            }
            button.setAttributedTitle(label, for: .normal)
            button.accessibilityLabel = symbols ? title : "한글 \(korean), 영문 \(key), 현재 \(title)"
        }
    }

    private func addPreview(to button: UIButton, text: @escaping () -> String) {
        previewText[ObjectIdentifier(button)] = text
        button.addTarget(self, action: #selector(showPreview(_:)), for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(hidePreview(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    @objc private func showPreview(_ button: UIButton) {
        guard let text = previewText[ObjectIdentifier(button)]?() else { return }
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
        alternates[ObjectIdentifier(button)] = alternate
        button.accessibilityHint = "길게 눌러 \(alternate) 입력"
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdAlternate(_:)))
        hold.minimumPressDuration = 0.4
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
    }

    @objc private func holdAlternate(_ hold: UILongPressGestureRecognizer) {
        guard let button = hold.view as? UIButton, let alternate = alternates[ObjectIdentifier(button)] else { return }
        switch hold.state {
        case .ended:
            dismissPreview()
            emitLiteral(alternate)
            if shifted { shifted = false; refresh() }
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
        if window == nil { dismissPreview() }
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
        button.addAction(UIAction { _ in action() }, for: event)
        return button
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

