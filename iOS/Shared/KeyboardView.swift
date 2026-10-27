import UIKit

/// Touch keyboard uses standard Korean two-set and English QWERTY positions.
@MainActor
final class KeyboardView: UIView {
    static let preferredHeight: CGFloat = 280

    var onKey: ((Character) -> Void)?
    var onPhrase: ((String) -> Void)?
    var onLiteral: ((Character) -> Void)?
    var onDelete: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: ((UIButton, UIEvent) -> Void)?
    var onAutoSwitch: (() -> Void)?
    var showsInputModeSwitch = true { didSet { globe.isHidden = !showsInputModeSwitch } }
    private let globe = UIButton(type: .system)
    private var shifted = false
    private var english = false
    private var hostEnglish = false
    private var symbols = false
    private let rows = UIStackView()
    private let phraseBar = UIStackView()
    private var phrases = UserDefaults.standard.stringArray(forKey: "quickPhrases") ?? []
    private var phraseSession: Session?
    private var editingPhraseIndex: Int?
    private var numberKeys: [(UIButton, Character, Character)] = []
    private var keys: [(UIButton, Character)] = []

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
                keys.append((button, character))
                row.addArrangedSubview(button)
            }
            if letters.count < 10 {
                let inset = UIStackView()
                let leading: UIView
                let trailing: UIView
                if letters.count == 7 {
                    leading = makeButton("⇧") { [weak self] in self?.shifted.toggle(); self?.refresh() }
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
        controls.addArrangedSubview(globe)
        let symbolKey = makeButton("#") { [weak self] in
            self?.symbols.toggle(); self?.refresh()
        }
        symbolKey.accessibilityLabel = "기호 자판 전환"
        controls.addArrangedSubview(symbolKey)
        let languageKey = makeButton("↔") { [weak self] in self?.toggleLanguage() }
        languageKey.accessibilityLabel = "한영 전환 및 자동 변환 되돌리기"
        controls.addArrangedSubview(languageKey)
        let space = makeButton("간격") { [weak self] in self?.emitKey(" ") }
        space.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        controls.addArrangedSubview(space)
        for punctuation: Character in [".", "?"] {
            let punctuationKey = makeButton(String(punctuation)) { [weak self] in
                guard let self else { return }
                self.emitLiteral(punctuation)
                if self.shifted { self.shifted = false; self.refresh() }
            }
            controls.addArrangedSubview(punctuationKey)
            punctuationKey.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: 0.105).isActive = true
        }
        controls.addArrangedSubview(makeButton("↵") { [weak self] in self?.emitKey("\n") })
        for case let button as UIButton in controls.arrangedSubviews {
            button.titleLabel?.font = .systemFont(ofSize: 16)
            if button !== space && button.title(for: .normal) != "." && button.title(for: .normal) != "?" {
                button.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: 0.105).isActive = true
            }
        }
        rows.addArrangedSubview(controls)
        for row in rows.arrangedSubviews.dropFirst() {
            row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(mode: Language, automatic: Bool) {
        hostEnglish = mode == .english
        if phraseSession == nil { english = hostEnglish }
        refresh()
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
        editingPhraseIndex = index
        let editor = Session(lexicon: Lexicon(english: [], korean: []), autoSwitch: false, mode: english ? .english : .korean)
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
            for button in phraseBar.arrangedSubviews.compactMap({ $0 as? UIButton }) {
                button.titleLabel?.font = .systemFont(ofSize: 13)
                button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            }
            return
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

    private func style(_ button: UIButton) {
        button.backgroundColor = .tertiarySystemBackground
        button.layer.cornerRadius = 5
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.setTitleColor(.label, for: .normal)
    }

    private func makeButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        style(button)
        button.setTitle(title, for: .normal)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}
