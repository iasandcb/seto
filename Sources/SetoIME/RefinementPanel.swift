import AppKit
import SetoCore

/// A floating, non-activating panel below the caret. It never becomes key,
/// so the client app keeps focus and keys keep coming to the input method.
@MainActor
final class RefinementPanel {
    enum Content: Equatable, Sendable {
        case loading(original: String)
        case suggestion(original: String, suggestion: String, index: Int, count: Int)
        case message(String)
    }

    private static let maxWidth: CGFloat = 480
    private static let padding: CGFloat = 12
    private static let gap: CGFloat = 6

    private let panel: NonActivatingPanel
    private let background = NSVisualEffectView()
    private let stack = NSStackView()
    /// The caret rectangle in screen coordinates the panel hangs from.
    private var anchor: NSRect = .zero

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding,
                                        bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    /// Shows `content` hanging below `caret` (screen coordinates). A zero
    /// rectangle keeps the previous anchor, or uses the mouse location.
    func show(_ content: Content, below caret: NSRect? = nil) {
        if let caret {
            anchor = caret == .zero ? NSRect(origin: NSEvent.mouseLocation, size: .zero) : caret
        }
        render(content)
        layout()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    // MARK: - Content

    private func render(_ content: Content) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        switch content {
        case .loading(let original):
            add(caption("원문"))
            add(body(NSAttributedString(string: original, attributes: Self.bodyAttributes)))
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let row = NSStackView(views: [spinner, caption("다듬는 중…")])
            row.spacing = 6
            add(row)
            add(hint("esc 취소"))
        case .suggestion(let original, let suggestion, let index, let count):
            let segments = TextDiff.diff(original, suggestion)
            add(caption("원문"))
            add(body(Self.highlighted(segments, showing: .removed)))
            add(caption(count > 1 ? "제안 \(index + 1)/\(count)" : "제안"))
            add(body(Self.highlighted(segments, showing: .added)))
            add(hint(original == suggestion
                ? "고칠 곳이 없습니다   ⇥ 다른 제안  esc 닫기"
                : "↩ 바꾸기  ⇥ 다른 제안  esc 취소"))
        case .message(let message):
            add(body(NSAttributedString(string: message, attributes: Self.bodyAttributes)))
            add(hint("esc 닫기"))
        }
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
    }

    private static let bodyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.labelColor,
    ]

    private enum Side { case removed, added }

    /// The original with removals struck out, or the suggestion with
    /// additions highlighted.
    private static func highlighted(_ segments: [TextDiff.Segment], showing side: Side) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            switch (segment, side) {
            case (.same(let text), _):
                result.append(NSAttributedString(string: text, attributes: bodyAttributes))
            case (.removed(let text), .removed):
                var attributes = bodyAttributes
                attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.25)
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = NSColor.systemRed
                result.append(NSAttributedString(string: text, attributes: attributes))
            case (.added(let text), .added):
                var attributes = bodyAttributes
                attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.3)
                result.append(NSAttributedString(string: text, attributes: attributes))
            case (.removed, .added), (.added, .removed):
                break
            }
        }
        return result
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func body(_ text: NSAttributedString) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.isSelectable = false
        label.preferredMaxLayoutWidth = Self.maxWidth - 2 * Self.padding
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    // MARK: - Placement

    private func layout() {
        let fitting = stack.fittingSize
        let size = NSSize(width: min(Self.maxWidth, max(160, ceil(fitting.width))),
                          height: ceil(fitting.height))
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = NSPoint(x: anchor.minX, y: anchor.minY - Self.gap - size.height)
        if origin.y < visible.minY {
            // No room below the caret: hang above it instead.
            origin.y = anchor.maxY + Self.gap
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Never key or main, so showing it does not take focus from the client.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
