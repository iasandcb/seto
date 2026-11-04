import AppKit
import Carbon
import InputMethodKit
import SetoCore

/// ⌃⇧L: select back to the start of the sentence before the caret, ask the
/// on-device model for a refinement and show it in a panel below the caret.
/// While the panel is open, Return replaces the selection, Tab asks for
/// another wording, Esc keeps the original, and any other key closes the
/// panel and types normally.
///
/// IMK calls in on the main thread; panel access goes through
/// MainActor.assumeIsolated like the rest of the input method.
final class SentenceRefinementController {
    /// Where the selected sentence lives, and how to replace it.
    private enum Target {
        /// A range in client coordinates; insertText replaces it directly.
        case client(NSRange)
        /// A range in the element's Accessibility coordinates. Selected again
        /// before insertText replaces the selection.
        case accessibility(AXUIElement, NSRange)
        /// The app's own selection after a synthesized ⇧⌘←.
        case currentSelection
    }

    private enum Selection {
        case found(String, Target)
        /// Text was readable, but the caret directly follows a boundary.
        case empty
        /// This route could not read the text.
        case unavailable
    }

    private enum Outcome: Sendable {
        case refined(String)
        case failed(String)
    }

    private static let windowLength = 2_000
    private static let maximumSuggestions = 5
    /// Some editors end composition right after the selection changes. That
    /// echo of our own selection must not close the panel it opens.
    private static let commitGracePeriod: TimeInterval = 0.3
    private static let permissionMessage = "손쉬운 사용 권한이 필요합니다 (시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용)"
    private static let noSentenceMessage = "다듬을 문장이 없습니다"
    private static let unreadableMessage = "현재 앱에서 문장을 가져올 수 없습니다"

    private weak var owner: IMKInputController?
    private var panel: RefinementPanel?
    private var isOpen = false
    private var openedAt = Date.distantPast
    private var target: Target?
    private var original = ""
    private var suggestions: [String] = []
    private var index = 0
    private var loading = false
    /// Bumped on every request and on close; older results are dropped.
    private var generation = 0
    private lazy var reference = WeakRefinementController(self)

    init(owner: IMKInputController) {
        self.owner = owner
    }

    deinit {
        guard let panel else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { panel.close() }
        } else {
            Task { @MainActor in panel.close() }
        }
    }

    // MARK: - Hooks for the input controller

    /// Starts a refinement. Compose state must already be committed. Returns
    /// false when the key should pass through (secure input).
    func begin(client: IMKTextInput) -> Bool {
        guard !IsSecureEventInputEnabled() else { return false }
        close()
        switch clientSelection(client) {
        case .found(let text, let target):
            present(text, target: target, client: client)
            return true
        case .empty:
            showMessage(Self.noSentenceMessage, client: client)
            return true
        case .unavailable:
            break
        }
        guard AXIsProcessTrusted() else {
            FocusedElementReader.requestTrustIfNeeded()
            showMessage(Self.permissionMessage, client: client)
            return true
        }
        switch accessibilitySelection() {
        case .found(let text, let target):
            present(text, target: target, client: client)
        case .empty:
            showMessage(Self.noSentenceMessage, client: client)
        case .unavailable:
            selectWithKeystroke()
        }
        return true
    }

    /// Handles a keyDown while the panel is open. nil lets the key continue
    /// through normal input handling.
    func handleKey(_ event: NSEvent, client: IMKTextInput) -> Bool? {
        guard isOpen, event.type == .keyDown else { return nil }
        if IsSecureEventInputEnabled() {
            close()
            return nil
        }
        switch event.keyCode {
        case 0x24, 0x4C: // Return, Enter
            if !loading, index < suggestions.count, let problem = replace(client: client) {
                showMessage(problem, client: nil)
            } else {
                close()
            }
            return true
        case 0x35: // Escape
            close()
            return true
        case 0x30: // Tab
            nextSuggestion()
            return true
        default:
            close()
            return nil
        }
    }

    /// The client committed composition, e.g. after a click elsewhere.
    func closeAfterCommit() {
        guard isOpen, Date().timeIntervalSince(openedAt) > Self.commitGracePeriod else { return }
        close()
    }

    func close() {
        generation += 1
        loading = false
        target = nil
        original = ""
        suggestions = []
        index = 0
        guard isOpen else { return }
        isOpen = false
        if let panel {
            MainActor.assumeIsolated { panel.close() }
        }
    }

    // MARK: - Selecting the sentence

    /// Reads a bounded window ending at the caret from the client itself.
    private func clientSelection(_ client: IMKTextInput) -> Selection {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound else { return .unavailable }
        if selection.length > 0 {
            guard let text = read(client, selection) else { return .unavailable }
            return .found(text, .client(selection))
        }
        let caret = selection.location
        let windowStart = max(0, caret - Self.windowLength)
        let window = NSRange(location: windowStart, length: caret - windowStart)
        // Nothing before the caret, or a client that cannot say: let
        // Accessibility decide.
        guard window.length > 0, let text = read(client, window) else { return .unavailable }
        let start = sentenceStart(in: text, before: window.length, cut: windowStart > 0)
        let local = NSRange(location: start, length: window.length - start)
        guard local.length > 0 else { return .empty }
        let range = NSRange(location: windowStart + start, length: local.length)
        let sentence = (text as NSString).substring(with: local)

        // IMKTextInput cannot set the selection, so show it through
        // Accessibility, which usually shares the client's coordinates.
        // Replacement uses the client range, so it works unselected too.
        if let context = FocusedElementReader.textContext() {
            _ = FocusedElementReader.select(range, in: context.element)
        }
        return .found(sentence, .client(range))
    }

    private func accessibilitySelection() -> Selection {
        guard let context = FocusedElementReader.textContext() else { return .unavailable }
        let document = context.document as NSString
        let selection = context.selection
        guard NSMaxRange(selection) <= document.length else { return .unavailable }
        if selection.length > 0 {
            let range = NSRange(location: context.documentStart + selection.location, length: selection.length)
            return .found(document.substring(with: selection), .accessibility(context.element, range))
        }
        let start = sentenceStart(in: context.document, before: selection.location,
                                  cut: context.documentStart > 0)
        let local = NSRange(location: start, length: selection.location - start)
        guard local.length > 0 else { return .empty }
        let range = NSRange(location: context.documentStart + start, length: local.length)
        _ = FocusedElementReader.select(range, in: context.element)
        return .found(document.substring(with: local), .accessibility(context.element, range))
    }

    /// Without readable text, ask the app to select to the line start with
    /// ⇧⌘← and read back what it selected.
    private func selectWithKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: keyDown) else { continue }
            event.flags = [.maskShift, .maskCommand]
            event.post(tap: .cghidEventTap)
        }
        let expected = generation
        let reference = reference
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            reference.value?.finishKeystrokeSelection(generation: expected)
        }
    }

    private func finishKeystrokeSelection(generation expected: Int) {
        guard expected == generation, let client = owner?.client() else { return }
        let selection = client.selectedRange()
        if selection.location != NSNotFound, selection.length > 0, let text = read(client, selection) {
            present(text, target: .client(selection), client: client)
        } else if let text = FocusedElementReader.selectedText(), !text.isEmpty {
            present(text, target: .currentSelection, client: client)
        } else {
            showMessage(Self.unreadableMessage, client: client)
        }
    }

    private func sentenceStart(in text: String, before caret: Int, cut: Bool) -> Int {
        var start = SentenceBoundary.start(in: text, before: caret)
        // A window cut from a longer document can begin with half a
        // surrogate pair, which arrives as U+FFFD. Do not select it.
        if cut, start == 0, start < caret, let first = text.utf16.first,
           first == 0xFFFD || UTF16.isTrailSurrogate(first) {
            start = 1
        }
        return start
    }

    /// The client's text in `range`, if it returns exactly that much.
    private func read(_ client: IMKTextInput, _ range: NSRange) -> String? {
        guard let text = client.attributedSubstring(from: range)?.string,
              (text as NSString).length == range.length else { return nil }
        return text
    }

    // MARK: - Refinement

    private func present(_ text: String, target: Target, client: IMKTextInput) {
        self.target = target
        original = text
        suggestions = []
        index = 0
        let anchor = caretRect(client, target: target)
        guard #available(macOS 26.0, *) else {
            show(.message("문장 다듬기는 macOS 26 이상에서 Apple Intelligence로 동작합니다"), anchor: anchor)
            return
        }
        if let reason = SentenceRefiner.unavailableReason {
            show(.message(reason), anchor: anchor)
            return
        }
        show(.loading(original: text), anchor: anchor)
        request()
    }

    @available(macOS 26.0, *)
    private func request() {
        generation += 1
        let expected = generation
        loading = true
        let text = original
        let previous = suggestions
        let reference = reference
        Task.detached {
            let outcome: Outcome
            do {
                outcome = .refined(try await SentenceRefiner.shared.refine(text, avoiding: previous))
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                reference.value?.receive(outcome, generation: expected)
            }
        }
    }

    private func receive(_ outcome: Outcome, generation expected: Int) {
        guard expected == generation, isOpen else { return }
        loading = false
        switch outcome {
        case .refined(let suggestion) where !suggestion.isEmpty:
            if let existing = suggestions.firstIndex(of: suggestion) {
                index = existing
            } else {
                suggestions.append(suggestion)
                index = suggestions.count - 1
            }
            showSuggestion()
        case .refined:
            failed("빈 결과를 받았습니다")
        case .failed(let message):
            failed(message)
        }
    }

    private func failed(_ message: String) {
        if suggestions.isEmpty {
            show(.message("다듬지 못했습니다: \(message)"), anchor: nil)
        } else {
            showSuggestion()
        }
    }

    private func nextSuggestion() {
        guard !loading, !suggestions.isEmpty else { return }
        guard suggestions.count < Self.maximumSuggestions, #available(macOS 26.0, *) else {
            index = (index + 1) % suggestions.count
            showSuggestion()
            return
        }
        show(.loading(original: original), anchor: nil)
        request()
    }

    /// Replaces the target with the shown suggestion. Returns a message when
    /// it did not.
    private func replace(client: IMKTextInput) -> String? {
        guard let target else { return nil }
        let suggestion = suggestions[index]
        guard suggestion != original else { return nil }
        let selection = NSRange(location: NSNotFound, length: 0)
        switch target {
        case .client(let range):
            if let current = read(client, range), current != original {
                return "문장이 바뀌어 바꾸지 않았습니다"
            }
            client.insertText(suggestion, replacementRange: range)
        case .accessibility(let element, let range):
            guard FocusedElementReader.select(range, in: element) else {
                return "문장을 다시 선택하지 못해 바꾸지 않았습니다"
            }
            client.insertText(suggestion, replacementRange: selection)
        case .currentSelection:
            client.insertText(suggestion, replacementRange: selection)
        }
        return nil
    }

    // MARK: - Panel

    private func showSuggestion() {
        show(.suggestion(original: original, suggestion: suggestions[index],
                         index: index, count: suggestions.count), anchor: nil)
    }

    /// A message after the target is gone keeps the panel where it is.
    private func showMessage(_ message: String, client: IMKTextInput?) {
        let anchor = client.map { caretRect($0, target: nil) }
        target = nil
        suggestions = []
        loading = false
        show(.message(message), anchor: anchor)
    }

    /// nil keeps the current position; .zero means the mouse location.
    private func show(_ content: RefinementPanel.Content, anchor: NSRect?) {
        let panel = panel ?? MainActor.assumeIsolated { RefinementPanel() }
        self.panel = panel
        if !isOpen { openedAt = Date() }
        isOpen = true
        MainActor.assumeIsolated {
            panel.show(content, below: anchor ?? (panel.isVisible ? nil : .zero))
        }
    }

    /// The caret at the end of the selection, in screen coordinates, or
    /// .zero when the client cannot say.
    private func caretRect(_ client: IMKTextInput, target: Target?) -> NSRect {
        let range: NSRange
        if case .client(let selected)? = target {
            range = selected
        } else {
            range = client.selectedRange()
        }
        var actual = NSRange()
        if range.location != NSNotFound {
            let caret = NSRange(location: NSMaxRange(range), length: 0)
            let rect = client.firstRect(forCharacterRange: caret, actualRange: &actual)
            if rect != .zero { return rect }
            let first = client.firstRect(forCharacterRange: range, actualRange: &actual)
            if first != .zero { return first }
        }
        var line = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &line)
        return line
    }
}

private final class WeakRefinementController: @unchecked Sendable {
    weak var value: SentenceRefinementController?

    init(_ value: SentenceRefinementController) {
        self.value = value
    }
}
