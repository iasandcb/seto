import AppKit
import Sebeol390Core

/// Show the confirmed mode without switching macOS input sources, which can
/// interrupt a composition. All status-item access stays on the main actor.
@MainActor
final class ModeStatusItem {
    static let shared = ModeStatusItem()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var owner: ObjectIdentifier?
    private var displayedMode: Language?
    private var displayedLayout: KeyboardLayout?
    private var displayedAutoSwitch: Bool?

    private init() {
        item.isVisible = false
        item.button?.font = .systemFont(ofSize: 14, weight: .semibold)
    }

    func activate(owner: ObjectIdentifier, mode: Language, layout: KeyboardLayout = .sebeol390,
                  autoSwitch: Bool, menu: NSMenu) {
        self.owner = owner
        item.menu = menu
        update(owner: owner, mode: mode, layout: layout, autoSwitch: autoSwitch)
        item.isVisible = true
    }

    func update(owner: ObjectIdentifier, mode: Language, layout: KeyboardLayout = .sebeol390,
                autoSwitch: Bool) {
        guard self.owner == owner,
              displayedMode != mode || displayedLayout != layout || displayedAutoSwitch != autoSwitch else { return }
        let language = mode == .korean ? "한글 (\(layout.title))" : "영문 (QWERTY)"
        let automatic = autoSwitch ? "자동전환 켜짐" : "자동전환 꺼짐"
        let description = "세토 · \(language) · \(automatic)"
        let modeTitle = mode == .korean ? "한" : "A"
        let switchMark = autoSwitch ? "○" : "–"
        // Match the optical baseline of neighboring menu-bar icons.
        let title = NSMutableAttributedString(
            string: modeTitle + switchMark,
            attributes: [.baselineOffset: -1]
        )
        title.addAttributes([
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ], range: NSRange(location: 0, length: (modeTitle as NSString).length))
        title.addAttributes([
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: autoSwitch ? NSColor.white : NSColor.secondaryLabelColor,
        ], range: NSRange(location: (modeTitle as NSString).length, length: (switchMark as NSString).length))
        item.button?.attributedTitle = title
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)
        displayedMode = mode
        displayedLayout = layout
        displayedAutoSwitch = autoSwitch
    }

    func hide(owner: ObjectIdentifier) {
        // An older client's deactivation must not hide the new client's mode.
        guard self.owner == owner else { return }
        item.isVisible = false
        item.menu = nil
        self.owner = nil
        displayedMode = nil
        displayedLayout = nil
        displayedAutoSwitch = nil
    }
}
