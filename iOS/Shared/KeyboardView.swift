import UIKit

/// Physical QWERTY positions retain the desktop engine's 390 mapping.
@MainActor
final class KeyboardView: UIView {
    var onKey: ((Character) -> Void)?
    var onLiteral: ((Character) -> Void)?
    var onDelete: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: ((UIButton, UIEvent) -> Void)?
    var onAutoSwitch: (() -> Void)?
    private var shifted = false
    private var english = false
    private var symbols = false
    private let rows = UIStackView()
    private let status = UIButton(type: .system)
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
        status.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        status.addAction(UIAction { [weak self] _ in self?.onAutoSwitch?() }, for: .touchUpInside)
        rows.addArrangedSubview(status)
        for letters in ["1234567890", "qwertyuiop", "asdfghjkl;", "zxcvbnm,./"] {
            let row = UIStackView()
            row.spacing = 4
            row.distribution = .fillEqually
            for character in letters {
                let button = makeButton("") { [weak self] in
                    guard let self else { return }
                    let output = self.output(character)
                    if self.symbols { self.onLiteral?(output) } else { self.onKey?(output) }
                    if self.shifted { self.shifted = false; self.refresh() }
                }
                keys.append((button, character))
                row.addArrangedSubview(button)
            }
            rows.addArrangedSubview(row)
        }
        let controls = UIStackView()
        controls.spacing = 4
        controls.distribution = .fillProportionally
        controls.addArrangedSubview(makeButton("⇧") { [weak self] in
            self?.shifted.toggle(); self?.refresh()
        })
        let globe = UIButton(type: .system)
        style(globe)
        globe.setTitle("🌐", for: .normal)
        globe.accessibilityLabel = "다음 키보드"
        globe.addTarget(self, action: #selector(nextKeyboard(_:event:)), for: .allTouchEvents)
        controls.addArrangedSubview(globe)
        controls.addArrangedSubview(makeButton("123") { [weak self] in
            self?.symbols.toggle(); self?.refresh()
        })
        controls.addArrangedSubview(makeButton("한/영 ↶") { [weak self] in self?.onToggle?() })
        let space = makeButton("간격") { [weak self] in self?.onKey?(" ") }
        space.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        controls.addArrangedSubview(space)
        controls.addArrangedSubview(makeButton("⌫") { [weak self] in self?.onDelete?() })
        controls.addArrangedSubview(makeButton("↵") { [weak self] in self?.onKey?("\n") })
        rows.addArrangedSubview(controls)
        for row in rows.arrangedSubviews.dropFirst() {
            row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(mode: Language, automatic: Bool) {
        english = mode == .english
        status.setTitle("세토 · \(english ? "영문" : "세벌식 390") · 자동 전환 \(automatic ? "켬" : "끔")", for: .normal)
        refresh()
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
        for (button, character) in keys {
            let key = output(character)
            let title: String
            if english || symbols { title = String(key) }
            else {
                switch Layout390.atom(for: key).korean {
                case .jamo(let jamo): title = String(jamo.compat)
                case .character(let value): title = String(value)
                }
            }
            button.setTitle(title, for: .normal)
            button.accessibilityLabel = "\(title), \(key)"
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
