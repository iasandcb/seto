import AppKit
import Sebeol390Core

/// Show the confirmed mode without switching macOS input sources, which can
/// interrupt a composition. All status-item access stays on the main actor.
@MainActor
final class ModeStatusItem {
    static let shared = ModeStatusItem()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var owner: ObjectIdentifier?
    private var displayedMode: Language?

    private init() {
        item.isVisible = false
        item.button?.font = .systemFont(ofSize: 14, weight: .semibold)
    }

    func activate(owner: ObjectIdentifier, mode: Language, menu: NSMenu) {
        self.owner = owner
        item.menu = menu
        update(owner: owner, mode: mode)
        item.isVisible = true
    }

    func update(owner: ObjectIdentifier, mode: Language) {
        guard self.owner == owner, displayedMode != mode else { return }
        let description = mode == .korean ? "세토 · 한글 (세벌식 390)" : "세토 · 영문 (QWERTY)"
        item.button?.title = mode == .korean ? "한" : "A"
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)
        displayedMode = mode
    }

    func hide(owner: ObjectIdentifier) {
        // An older client's deactivation must not hide the new client's mode.
        guard self.owner == owner else { return }
        item.isVisible = false
        item.menu = nil
        self.owner = nil
        displayedMode = nil
    }
}
