import XCTest
import WebKit
@testable import Sebeol390

final class HardwareTextEditorTests: XCTestCase {
    @MainActor func testCompositionDeletionAndSelection() async {
        let view = HardwareTextView()
        view.text = "앞 👨‍👩‍👧‍👦 "
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        view.resetSession()
        for usage in [14, 9, 27] { XCTAssertTrue(view.handleKey(usage: usage)) }
        XCTAssertEqual(view.text, "앞 👨‍👩‍👧‍👦 각")
        XCTAssertTrue(view.handleKey(usage: 42))
        XCTAssertEqual(view.text, "앞 👨‍👩‍👧‍👦 가")
        // Move to the beginning; the old composition must remain intact.
        view.selectedRange = NSRange(location: 0, length: 0)
        for usage in [14, 9] { view.handleKey(usage: usage) }
        XCTAssertEqual(view.text, "가앞 👨‍👩‍👧‍👦 가")
        view.selectedRange = NSRange(location: 0, length: 2)
        for usage in [14, 9] { view.handleKey(usage: usage) }
        XCTAssertEqual(view.text, "가 👨‍👩‍👧‍👦 가")
    }

    @MainActor func testShiftSpaceAndNativeEdits() async {
        let view = HardwareTextView()
        view.handleKey(usage: 14)
        // Shift by itself must not commit ㄱ.
        XCTAssertFalse(view.handleKey(usage: 225, flags: .shift))
        view.handleKey(usage: 9)
        XCTAssertEqual(view.text, "가")
        view.handleKey(usage: 44, flags: .shift)
        XCTAssertEqual(view.text, "kf") // The current token changes reading too.
        view.handleKey(usage: 4)
        XCTAssertEqual(view.text, "kfa")
        XCTAssertFalse(view.handleKey(usage: 6, flags: .command))
        XCTAssertEqual(view.text, "kfa")
        // Native paste and a new selection must not be replaced by stale state.
        view.text = "붙여넣기"
        view.selectedRange = NSRange(location: 4, length: 0)
        view.handleKey(usage: 5)
        XCTAssertEqual(view.text, "붙여넣기b")
        view.selectedRange = NSRange(location: 0, length: 4)
        view.handleKey(usage: 42)
        XCTAssertEqual(view.text, "b")
    }

    @MainActor func testSpaceDragCursorStepsAndCommitsComposition() async {
        var drag = CursorDrag(start: CGPoint(x: 100, y: 50))
        // Jitter under one step stays a plain hold, which still types a tab.
        XCTAssertEqual(drag.update(to: CGPoint(x: 105, y: 60)), CursorStep())
        XCTAssertFalse(drag.isDragging)
        XCTAssertEqual(drag.update(to: CGPoint(x: 79, y: 50)).characters, -2)
        XCTAssertTrue(drag.isDragging)
        XCTAssertEqual(drag.update(to: CGPoint(x: 111, y: 50)).characters, 3)
        XCTAssertEqual(drag.update(to: CGPoint(x: 100, y: 50)).characters, -1)
        XCTAssertTrue(drag.isDragging) // Returning to the start does not revert to a tab.

        let view = HardwareTextView()
        view.text = "앞👨‍👩‍👧‍👦뒤"
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        view.resetSession()
        for usage in [14, 9] { view.handleKey(usage: usage) }
        XCTAssertEqual(view.text, "앞👨‍👩‍👧‍👦뒤가")
        view.moveCursor(by: -2)
        XCTAssertEqual(view.selectedRange, NSRange(location: ("앞👨‍👩‍👧‍👦" as NSString).length, length: 0))
        view.moveCursor(by: -5)
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
        view.moveCursor(by: 2)
        // The moved-away composition is committed: new input does not edit 가.
        for usage in [14, 9] { view.handleKey(usage: usage) }
        XCTAssertEqual(view.text, "앞👨‍👩‍👧‍👦가뒤가")
        view.moveCursor(by: 9)
        XCTAssertEqual(view.selectedRange.location, (view.text as NSString).length)
    }

    func testSpaceDragVerticalTravelBecomesLineSteps() {
        var drag = CursorDrag(start: CGPoint(x: 100, y: 100))
        // A sideways slide with a little vertical drift stays on the line.
        XCTAssertEqual(drag.update(to: CGPoint(x: 130, y: 115)), CursorStep(characters: 3, lines: 0))
        XCTAssertEqual(drag.update(to: CGPoint(x: 130, y: 75)), CursorStep(characters: 0, lines: -1))
        XCTAssertTrue(drag.isDragging)
        XCTAssertEqual(drag.update(to: CGPoint(x: 130, y: 51)), CursorStep(characters: 0, lines: -1))
        XCTAssertEqual(drag.update(to: CGPoint(x: 130, y: 125)), CursorStep(characters: 0, lines: 3))

        // Vertical travel alone is a drag too, so release does not type a tab.
        var vertical = CursorDrag(start: CGPoint(x: 100, y: 100))
        XCTAssertEqual(vertical.update(to: CGPoint(x: 104, y: 70)), CursorStep(characters: 0, lines: -1))
        XCTAssertTrue(vertical.isDragging)
    }

    func testCursorMotionKeepsVisualColumnAcrossLines() {
        func up(_ before: String, _ after: String = "", lines: Int = -1, goal: Int? = nil) -> CursorMotion {
            CursorMotion.resolve(before: before, after: after, step: CursorStep(lines: lines), goalColumn: goal)
        }
        // Same width: the same column on the line above.
        XCTAssertEqual(up("abcdef\nabc"), CursorMotion(utf16Offset: -7, goalColumn: 3))
        // Hangul is two columns wide: after "ab" (column 2) is after 가.
        XCTAssertEqual(up("가나다\nab"), CursorMotion(utf16Offset: -5, goalColumn: 2))
        // Column 3 is between 가 (2) and 가나 (4); the tie goes left.
        XCTAssertEqual(up("가나다\nabc"), CursorMotion(utf16Offset: -6, goalColumn: 3))
        // A short line above clamps to its end, still before the newline.
        XCTAssertEqual(up("ab\nabcdef"), CursorMotion(utf16Offset: -7, goalColumn: 6))
        // An emoji is one character (11 UTF-16 units here), two columns.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(up("\(family)x\nabc"), CursorMotion(utf16Offset: -4, goalColumn: 3))
        XCTAssertEqual(up("\(family)x\nab"), CursorMotion(utf16Offset: -3 - 1, goalColumn: 2))

        // Down uses the text after the caret.
        let down = CursorMotion.resolve(before: "x\nabc", after: "def\n가나다라\nz",
                                        step: CursorStep(lines: 1))
        // Column 3 on "가나다라" is a tie between 2 and 4: after 가.
        XCTAssertEqual(down, CursorMotion(utf16Offset: 3 + 1 + 1, goalColumn: 3))
        // Two lines down in one step passes through the middle line with the goal kept.
        let twoDown = CursorMotion.resolve(before: "abcdef", after: "\nab\nabcdefgh",
                                           step: CursorStep(lines: 2))
        XCTAssertEqual(twoDown, CursorMotion(utf16Offset: 1 + 2 + 1 + 6, goalColumn: 6))
        // The goal column from an earlier step wins over the current column.
        XCTAssertEqual(up("abcdefgh\nab", goal: 6), CursorMotion(utf16Offset: -5, goalColumn: 6))

        // No adjacent line in the known context: stay put.
        XCTAssertEqual(up("abc"), CursorMotion(utf16Offset: 0, goalColumn: nil))
        XCTAssertEqual(CursorMotion.resolve(before: "ab", after: "c", step: CursorStep(lines: 1)),
                       CursorMotion(utf16Offset: 0, goalColumn: nil))
        // A line step stops at the first missing line but keeps what it did.
        XCTAssertEqual(up("abc\nabc", lines: -3), CursorMotion(utf16Offset: -4, goalColumn: 3))

        // Sideways steps are whole characters and clear the goal column.
        XCTAssertEqual(CursorMotion.resolve(before: "a\(family)", after: "가b", step: CursorStep(characters: -1), goalColumn: 4),
                       CursorMotion(utf16Offset: -11, goalColumn: nil))
        XCTAssertEqual(CursorMotion.resolve(before: "a", after: "가b", step: CursorStep(characters: 2)),
                       CursorMotion(utf16Offset: 2, goalColumn: nil))
        // Beyond the known context the extension falls back to one unit per step.
        XCTAssertEqual(CursorMotion.resolve(before: "", after: "ab", step: CursorStep(characters: 4),
                                            extendsBeyondContext: true),
                       CursorMotion(utf16Offset: 4, goalColumn: nil))
        XCTAssertEqual(CursorMotion.resolve(before: "", after: "ab", step: CursorStep(characters: 4)),
                       CursorMotion(utf16Offset: 2, goalColumn: nil))
        XCTAssertEqual(CursorMotion.width("\t"), 4)
    }

    @MainActor func testSpaceDragMovesBetweenLinesAndCommitsComposition() async {
        let view = HardwareTextView()
        view.text = "가나다라\nab\nabcdefgh"
        let source = view.text as NSString
        view.selectedRange = NSRange(location: source.length, length: 0)
        view.resetSession()
        // Column 8 at the end of "abcdefgh"; the middle line is shorter.
        XCTAssertEqual(view.moveCursor(by: 0, lines: -1), 8)
        XCTAssertEqual(view.selectedRange, NSRange(location: 7, length: 0)) // End of "ab".
        // The kept goal brings the caret back to column 8: the end of 가나다라.
        XCTAssertEqual(view.moveCursor(by: 0, lines: -1, goalColumn: 8), 8)
        XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 0))
        // Nothing above the first line.
        view.moveCursor(by: 0, lines: -1, goalColumn: 8)
        XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 0))
        // From after 가 (column 2) down to after "ab".
        view.selectedRange = NSRange(location: 1, length: 0)
        XCTAssertEqual(view.moveCursor(by: 0, lines: 1), 2)
        XCTAssertEqual(view.selectedRange, NSRange(location: 7, length: 0))
        // Moving down starts from a selection's end ("a|b") and collapses it.
        view.selectedRange = NSRange(location: 0, length: 6)
        view.moveCursor(by: 0, lines: 1)
        XCTAssertEqual(view.selectedRange, NSRange(location: 9, length: 0)) // "a|bcdefgh"

        // A composition is committed before the caret leaves its line.
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        view.resetSession()
        for usage in [14, 9] { view.handleKey(usage: usage) }
        XCTAssertEqual(view.text, "가나다라\nab\nabcdefgh가")
        view.moveCursor(by: 0, lines: -2)
        XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 0))
        for usage in [14, 9] { view.handleKey(usage: usage) }
        XCTAssertEqual(view.text, "가나다라가\nab\nabcdefgh가")
    }
}

@MainActor
private final class TestPageLoader: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation
    init(_ finished: XCTestExpectation) { self.finished = finished }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished.fulfill() }
}

final class MarkVectorIntegrationTests: XCTestCase {
    @MainActor func testDocumentBridgeSaveAndConflict() async throws {
        let origin = "https://sebeol-test-" + UUID().uuidString.lowercased() + ".example"
        let connection = MarkVectorConnection(origin: origin)
        let loaded = expectation(description: "Mock mark-vector loaded")
        let loader = TestPageLoader(loaded)
        connection.webView.navigationDelegate = loader
        connection.webView.loadHTMLString("""
            <html><body><button id="save-btn">Save</button><script>
            localStorage.setItem('mark-vector:active-doc', JSON.stringify({role: 'document', projectId: '한글 project', sessionId: 'folder', filename: '문서.md'}));
            window.server = {content: '처음 내용', version: '1'};
            window.fetch = async (path, options = {}) => {
                window.lastPath = path;
                if (options.method === 'PUT') {
                    server = {content: JSON.parse(options.body).content, version: '2'};
                    window.putCount = (window.putCount || 0) + 1;
                }
                return {ok: true, status: 200, json: async () => ({...server})};
            };
            </script></body></html>
            """, baseURL: URL(string: origin)!)
        await fulfillment(of: [loaded], timeout: 15)
        await connection.openDocument()
        XCTAssertNil(connection.error)
        var document = try XCTUnwrap(connection.document)
        XCTAssertEqual(document.content, "처음 내용")
        XCTAssertTrue(document.path.contains("%ED%95%9C%EA%B8%80%20project"))
        document.content = "한글 👨‍👩‍👧‍👦 \"따옴표\"\n</script>"
        _ = try await connection.webView.evaluateJavaScript("server.version = 'changed'")
        do {
            _ = try await connection.save(document)
            XCTFail("Externally modified document must not be saved")
        } catch { XCTAssertTrue(error.localizedDescription.contains("다른 곳")) }
        let putsBefore = try await connection.webView.evaluateJavaScript("window.putCount || 0")
        XCTAssertEqual(putsBefore as? Int, 0)
        _ = try await connection.webView.evaluateJavaScript("server.version = '1'")
        // Block reload in this mock; verify the JS bridge payload on the page.
        let version = try await connection.save(document)
        connection.webView.stopLoading()
        XCTAssertEqual(version, "2")
    }

    @MainActor func testUnsavedWebDocumentIsRefused() async throws {
        let origin = "https://sebeol-dirty-" + UUID().uuidString.lowercased() + ".example"
        let connection = MarkVectorConnection(origin: origin)
        let loaded = expectation(description: "Unsaved mock loaded")
        let loader = TestPageLoader(loaded)
        connection.webView.navigationDelegate = loader
        connection.webView.loadHTMLString("""
            <html><body><button id="save-btn" class="dirty">Save</button><script>
            localStorage.setItem('mark-vector:active-doc', JSON.stringify({role:'document',projectId:'p',sessionId:'s',filename:'a.md'}));
            </script></body></html>
            """, baseURL: URL(string: origin)!)
        await fulfillment(of: [loaded], timeout: 15)
        await connection.openDocument()
        XCTAssertNil(connection.document)
        XCTAssertNotNil(connection.error)
    }
}

final class MarkVectorLiveSyncTests: XCTestCase {
    @MainActor func testCoalescesWhileWaitingForPersistenceAck() async throws {
        let live = MarkVectorLiveSync()
        var acknowledged: [String] = []
        live.onPersisted = { content, _ in acknowledged.append(content) }
        live.update("가")
        try live.receive(["type": "ready", "content": "", "version": "1"])
        let first = try XCTUnwrap(live.takeSnapshot())
        XCTAssertEqual(first.content, "가")
        live.update("각")
        live.update("가족 👨‍👩‍👧‍👦")
        XCTAssertNil(live.takeSnapshot())
        try live.receive(["type": "ack", "sequence": first.sequence + 99, "version": "wrong"])
        XCTAssertFalse(live.synchronized)
        try live.receive(["type": "ack", "sequence": first.sequence, "version": "2"])
        XCTAssertEqual(acknowledged, ["가"])
        XCTAssertFalse(live.synchronized)
        let second = try XCTUnwrap(live.takeSnapshot())
        XCTAssertEqual(second.content, "가족 👨‍👩‍👧‍👦")
        try live.receive(["type": "ack", "sequence": second.sequence, "version": "3"])
        XCTAssertTrue(live.synchronized)
        let version = try await live.flush()
        XCTAssertEqual(version, "3")
        // A reconnect snapshot never overwrites what was typed locally.
        try live.receive(["type": "ready", "content": "older", "version": "4"])
        XCTAssertEqual(live.takeSnapshot()?.content, "가족 👨‍👩‍👧‍👦")
        live.stop()
        XCTAssertFalse(live.synchronized)
    }

    @MainActor func testSocketURLUsesEncodedDocumentPath() async {
        let document = MarkVectorDocument(origin: "https://example.test", path: "/api/projects/p%20x/conversations/c/documents/a%23b.md", filename: "a#b.md", content: "", version: "1")
        XCTAssertEqual(MarkVectorLiveSync.socketURL(for: document)?.absoluteString, "wss://example.test/ws/documents/p%20x/c/a%23b.md?write=1")
    }
}

final class InputSettingsTests: XCTestCase {
    @MainActor func testAutomaticSettingSurvivesCursorAndFocusResets() async {
        let view = HardwareTextView()
        view.configure(automatic: false, mode: .english)
        for key in "hello " { view.inputCharacter(key) }
        XCTAssertEqual(view.text, "hello ")
        view.selectedRange = NSRange(location: 0, length: 0)
        view.resetSession()
        view.textViewDidEndEditing(view)
        view.textViewDidBeginEditing(view)
        XCTAssertFalse(view.session.autoSwitch)
        XCTAssertEqual(view.session.mode, Language.english)
        view.configure(automatic: true, mode: .english)
        view.resetSession()
        XCTAssertTrue(view.session.autoSwitch)
    }

    @MainActor func testModeControlCommitsWithoutChangingTextOrSelection() async {
        let view = HardwareTextView()
        view.configure(automatic: false, mode: .korean)
        for key in "kfx" { view.inputCharacter(key) }
        XCTAssertEqual(view.text, "각")
        let caret = view.selectedRange
        view.configure(automatic: false, mode: .english)
        XCTAssertEqual(view.text, "각")
        XCTAssertEqual(view.selectedRange, caret)
        XCTAssertEqual(view.session.mode, Language.english)
        view.inputCharacter("a")
        XCTAssertEqual(view.text, "각a")
    }

    @MainActor func testTouchUsesCurrentMacCoreAndReportsConfirmedMode() async throws {
        for (keys, expected, mode) in [
            ("hello ", "hello ", Language.english),
            ("gksrmf ", "한글 ", .korean),
            ("rkr", "각", .korean)
        ] {
            let view = HardwareTextView()
            view.configure(automatic: true, mode: mode)
            var displayedMode = mode
            view.onMode = { displayedMode = $0 }
            view.setHardwareKeyboardConnected(false)
            let keyboard = try XCTUnwrap(view.inputView as? TouchKeyboardInputView).keyboard
            for key in keys { keyboard.onKey?(key) }
            XCTAssertEqual(view.text, expected, keys)
            XCTAssertEqual(displayedMode, view.session.mode)
            if keys.hasPrefix("cd") || keys.hasPrefix("ls") { XCTAssertEqual(displayedMode, .english) }
            view.resetSession()
            XCTAssertEqual(displayedMode, view.session.mode)
        }
    }

    @MainActor func testTouchAutomaticSwitchUpdatesSettingsWithoutDiscardingComposition() async throws {
        let view = HardwareTextView()
        view.configure(automatic: true, mode: .korean)
        var setting = true
        view.onAutomatic = { setting = $0 }
        view.setHardwareKeyboardConnected(false)
        let keyboard = try XCTUnwrap(view.inputView as? TouchKeyboardInputView).keyboard
        keyboard.onKey?("r")
        keyboard.onKey?("k")
        keyboard.onAutoSwitch?()
        XCTAssertFalse(setting)
        XCTAssertFalse(view.session.autoSwitch)
        keyboard.onKey?("r")
        XCTAssertEqual(view.text, "각")
        view.resetSession()
        XCTAssertFalse(view.session.autoSwitch)
    }
}

final class TouchKeyboardLayoutTests: XCTestCase {
    @MainActor private func suggestionButtons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? suggestionButtons(in: $0) }
    }

    @MainActor private func waitForSuggestion(_ word: String, in keyboard: KeyboardView) async throws -> UIButton {
        for _ in 0..<100 {
            if let button = suggestionButtons(in: keyboard).first(where: {
                $0.accessibilityIdentifier == "wordSuggestion" && $0.accessibilityLabel == word
            }) { return button }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "WordSuggestionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing candidate: \(word)"])
    }

    @MainActor func testSuggestionsTogglePhrasesAndRespectBoundaries() async throws {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        keyboard.configureSuggestions(lexicon: Lexicon(english: [], korean: ["안녕", "안녕하세요"]))
        let context = WordSuggestionContext(before: "앞 안녕ㅎ", after: "")!
        keyboard.updateSuggestionContext(context)
        let candidate = try await waitForSuggestion("안녕하세요", in: keyboard)
        keyboard.layoutIfNeeded()
        XCTAssertGreaterThan(candidate.bounds.width, 0)
        XCTAssertEqual(keyboard.bounds.height, KeyboardView.preferredHeight)
        suggestionButtons(in: keyboard).first { $0.accessibilityIdentifier == "toggleSuggestions" }!.sendActions(for: .touchUpInside)
        XCTAssertNotNil(suggestionButtons(in: keyboard).first { $0.accessibilityLabel == "문구 등록" })
        XCTAssertFalse(suggestionButtons(in: keyboard).contains { $0.accessibilityIdentifier == "wordSuggestion" })
        // Keep the manually opened phrases while the same word is typed.
        keyboard.updateSuggestionContext(WordSuggestionContext(before: "앞 안녕하", after: ""))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(suggestionButtons(in: keyboard).contains { $0.accessibilityIdentifier == "wordSuggestion" })
        suggestionButtons(in: keyboard).first { $0.accessibilityIdentifier == "toggleSuggestions" }!.sendActions(for: .touchUpInside)
        _ = try await waitForSuggestion("안녕하세요", in: keyboard)
        keyboard.updateSuggestionContext(nil)
        XCTAssertNotNil(suggestionButtons(in: keyboard).first { $0.accessibilityLabel == "문구 등록" })
        var accepted = false
        keyboard.onSuggestion = { _, _ in accepted = true }
        candidate.sendActions(for: .touchUpInside)
        XCTAssertFalse(accepted, "A detached button must not accept stale context")
    }

    @MainActor func testCandidateReplacesWholeWordAndResetsComposition() async throws {
        let editor = HardwareTextView()
        editor.configure(automatic: false, mode: .korean)
        editor.hardwareKeyboardIsConnected = { false }
        editor.setHardwareKeyboardConnected(false)
        editor.text = "앞 👨‍👩‍👧‍👦 "
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.resetSession()
        let keyboard = (editor.inputView as! TouchKeyboardInputView).keyboard
        let keys = suggestionButtons(in: keyboard)
        for letter in "dkssudg" {
            keys.first { $0.accessibilityLabel?.contains("영문 \(letter),") == true }!.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(editor.text, "앞 👨‍👩‍👧‍👦 안녕ㅎ")
        let candidate = try await waitForSuggestion("안녕하세요", in: keyboard)
        candidate.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, "앞 👨‍👩‍👧‍👦 안녕하세요")
        XCTAssertTrue(editor.session.document.isEmpty)
        keys.first { $0.accessibilityLabel?.contains("영문 r,") == true }!.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, "앞 👨‍👩‍👧‍👦 안녕하세요ㄱ")
        editor.selectedRange = NSRange(location: 0, length: 0)
        candidate.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, "앞 👨‍👩‍👧‍👦 안녕하세요ㄱ")
    }

    @MainActor func testKeyPreviewFollowsPressAndDoesNotInsertEarly() {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        keyboard.showsInputModeSwitch = false
        keyboard.update(mode: .korean, automatic: true)
        keyboard.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let keys = descendants(keyboard).compactMap { $0 as? UIButton }
        let q = keys.first { $0.accessibilityLabel?.contains("영문 q,") == true }!
        let preview = descendants(keyboard).first { $0.accessibilityIdentifier == "keyPreview" }!
        let label = descendants(preview).first { $0.accessibilityIdentifier == "keyPreviewText" } as! UILabel
        var inserted: [Character] = []
        keyboard.onKey = { inserted.append($0) }
        q.sendActions(for: .touchDown)
        XCTAssertFalse(preview.isHidden)
        XCTAssertEqual(label.text, "ㅂ")
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertGreaterThanOrEqual(preview.frame.minX, 0)
        XCTAssertLessThanOrEqual(preview.frame.maxX, keyboard.bounds.width)
        q.sendActions(for: .touchUpInside)
        XCTAssertTrue(preview.isHidden)
        XCTAssertEqual(inserted, ["q"])
        keyboard.update(mode: .english, automatic: true)
        q.sendActions(for: .touchDown)
        XCTAssertEqual(label.text, "q")
        q.sendActions(for: .touchCancel)
        XCTAssertTrue(preview.isHidden)
        XCTAssertEqual(inserted, ["q"])
        let shift = keys.first { $0.title(for: .normal) == "⇧" }!
        shift.sendActions(for: .touchDown)
        let one = keys.first { $0.accessibilityLabel?.hasPrefix("숫자 1,") == true }!
        one.sendActions(for: .touchDown)
        XCTAssertEqual(label.text, "!")
        XCTAssertGreaterThanOrEqual(preview.frame.minY, 0)
        one.sendActions(for: .touchDragExit)
        XCTAssertTrue(preview.isHidden)
    }

    @MainActor func testDubeolEnglishWordAndParticleThroughTouchKeys() {
        for (spelling, expected) in [("apisms", "api는"), ("gitdms", "git은"), ("akadp emfdj", "맘에 들어"), ("akadp emfdjdy", "맘에 들어요")] {
            let editor = HardwareTextView()
            editor.hardwareKeyboardIsConnected = { false }
            editor.setHardwareKeyboardConnected(false)
            editor.configure(automatic: true, mode: .korean)
            let keyboard = (editor.inputView as! TouchKeyboardInputView).keyboard
            func buttons(in view: UIView) -> [UIButton] {
                view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
            }
            let keys = buttons(in: keyboard)
            for letter in spelling {
                if letter == " " { keys.first { $0.title(for: .normal) == "간격" }!.sendActions(for: .touchUpInside) }
                else { keys.first { $0.accessibilityLabel?.contains("영문 \(letter),") == true }!.sendActions(for: .touchUpInside) }
            }
            XCTAssertEqual(editor.text, expected)
            keys.first { $0.title(for: .normal) == "간격" }!.sendActions(for: .touchUpInside)
            XCTAssertEqual(editor.text, expected + " ")
        }
    }

    @MainActor func testBottomKeyWidthsAndDubeolAutoSwitch() throws {
        let editor = HardwareTextView()
        editor.hardwareKeyboardIsConnected = { false }
        editor.setHardwareKeyboardConnected(false)
        editor.configure(automatic: true, mode: .korean)
        let input = editor.inputView as! TouchKeyboardInputView
        input.frame = CGRect(x: 0, y: 0, width: 402, height: KeyboardView.preferredHeight)
        input.layoutIfNeeded()
        let keyboard = input.keyboard
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
        }
        let keys = buttons(in: keyboard)
        let letter = try XCTUnwrap(keys.first { $0.accessibilityLabel?.contains("영문 q,") == true })
        // The key left of space is "-", which inserts "-" and long-presses to "→".
        let titles = ["※", "↔", "-", ".", "?", "↵"]
        let bottom = try titles.map { title in
            try XCTUnwrap(keys.first { $0.title(for: .normal) == title }, "Missing bottom-row key \(title)")
        }
        // Stack views align frames to display pixels; equal constraints can
        // differ by one pixel after distributing a fractional key width.
        let pixel = 1 / input.traitCollection.displayScale
        for key in bottom { XCTAssertEqual(key.bounds.width, letter.bounds.width, accuracy: pixel + 0.001) }
        let space = try XCTUnwrap(keys.first { $0.title(for: .normal) == "간격" })
        let hyphen = bottom[2]
        XCTAssertEqual(hyphen.title(for: .normal), "-")
        XCTAssertLessThan(hyphen.convert(hyphen.bounds, to: keyboard).maxX, space.convert(space.bounds, to: keyboard).minX)
        for character in "world dkssudgktpdy " {
            if character == " " { space.sendActions(for: .touchUpInside) }
            else {
                let key = try XCTUnwrap(keys.first { $0.accessibilityLabel?.contains("영문 \(character),") == true })
                key.sendActions(for: .touchUpInside)
            }
        }
        XCTAssertEqual(editor.text, "world 안녕하세요 ")
        hyphen.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, "world 안녕하세요 -")
    }

    @MainActor func testHardwareConnectionHidesTouchKeyboardWithoutLosingComposition() {
        let editor = HardwareTextView()
        editor.configure(automatic: false, mode: .korean)
        editor.setHardwareKeyboardConnected(false)
        let software = editor.inputView
        editor.handleKey(usage: 14)
        editor.handleKey(usage: 9)
        XCTAssertEqual(editor.text, "가")
        let selection = editor.selectedRange
        editor.setHardwareKeyboardConnected(true)
        XCTAssertFalse(editor.inputView is TouchKeyboardInputView)
        XCTAssertEqual(editor.inputView?.bounds.height, 0)
        XCTAssertEqual(editor.text, "가")
        XCTAssertEqual(editor.selectedRange, selection)
        editor.handleKey(usage: 27)
        XCTAssertEqual(editor.text, "각")
        editor.setHardwareKeyboardConnected(false)
        XCTAssertTrue(editor.inputView === software)
        XCTAssertEqual(editor.text, "각")
    }

    @MainActor func testAppKeyboardKeepsBottomRowAboveSafeArea() {
        let keyboard = KeyboardView()
        let input = TouchKeyboardInputView(keyboard: keyboard)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.additionalSafeAreaInsets.bottom = 34
        host.view.addSubview(input)
        host.view.layoutIfNeeded()
        let height = KeyboardView.preferredHeight + host.view.safeAreaInsets.bottom
        input.frame = CGRect(x: 0, y: host.view.bounds.height - height, width: 390, height: height)
        host.view.layoutIfNeeded()
        input.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(input.safeAreaInsets.bottom, 34)
        XCTAssertTrue(input.allowsSelfSizing)
        XCTAssertEqual(input.systemLayoutSizeFitting(CGSize(width: 390, height: 0)).height, KeyboardView.preferredHeight + max(input.safeAreaInsets.bottom, window.safeAreaInsets.bottom), accuracy: 0.01)
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
        }
        let space = buttons(in: keyboard).first { $0.title(for: .normal) == "간격" }!
        let frame = space.convert(space.bounds, to: input)
        XCTAssertEqual(frame.height, 42, accuracy: 0.01)
        XCTAssertLessThanOrEqual(frame.maxY, input.bounds.height - input.safeAreaInsets.bottom - 6 + 0.01)
    }

    @MainActor func testQuickPhraseRegistrationAndInsertion() {
        let previous = UserDefaults.standard.object(forKey: "quickPhrases")
        defer { UserDefaults.standard.set(previous, forKey: "quickPhrases") }
        UserDefaults.standard.removeObject(forKey: "quickPhrases")
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
        }
        var document = ""
        keyboard.onKey = { document.append($0) }
        keyboard.onPhrase = { document += $0 }
        buttons(in: keyboard).first { $0.accessibilityLabel == "문구 등록" }!.sendActions(for: .touchUpInside)
        for letter in "gksrmf" {
            buttons(in: keyboard).first { $0.accessibilityLabel?.contains("영문 \(letter),") == true }!.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(document, "")
        buttons(in: keyboard).first { $0.accessibilityIdentifier == "savePhrase" }!.sendActions(for: .touchUpInside)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "quickPhrases"), ["한글"])
        buttons(in: keyboard).first { $0.accessibilityLabel == "한글" }!.sendActions(for: .touchUpInside)
        XCTAssertEqual(document, "한글")
        let reloaded = KeyboardView()
        XCTAssertNotNil(buttons(in: reloaded).first { $0.accessibilityLabel == "한글" })
    }

    @MainActor func testTouchUsesDubeolWhileHardwareKeeps390() {
        let editor = HardwareTextView()
        editor.configure(automatic: false, mode: .korean)
        editor.hardwareKeyboardIsConnected = { false }
        editor.setHardwareKeyboardConnected(false)
        let keyboard = (editor.inputView as! TouchKeyboardInputView).keyboard
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
        }
        let keys = buttons(in: keyboard)
        for letter in "gksrmf" {
            keys.first { $0.accessibilityLabel?.contains("영문 \(letter),") == true }!.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(editor.text, "한글")
        editor.handleKey(usage: 42)
        XCTAssertEqual(editor.text, "한그")
    }

    @MainActor private final class SimulatedHold: UILongPressGestureRecognizer {
        var simulatedState: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { simulatedState }
            set { simulatedState = newValue }
        }
    }

    @MainActor func testHyphenBesideSpaceAndExistingHoldAlternates() throws {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        keyboard.layoutIfNeeded()
        let keys = suggestionButtons(in: keyboard)
        let space = try XCTUnwrap(keys.first { $0.title(for: .normal) == "간격" })
        let controls = try XCTUnwrap(space.superview as? UIStackView)
        let spaceIndex = try XCTUnwrap(controls.arrangedSubviews.firstIndex(of: space))
        XCTAssertGreaterThan(spaceIndex, 0)
        let hyphen = try XCTUnwrap(controls.arrangedSubviews[spaceIndex - 1] as? UIButton)
        XCTAssertEqual(hyphen.title(for: .normal), "-")
        XCTAssertEqual(hyphen.accessibilityLabel, "하이픈 입력")
        XCTAssertEqual(hyphen.accessibilityHint, "길게 눌러 → 입력")
        var inserted: [Character] = []
        keyboard.onLiteral = { inserted.append($0) }
        keyboard.onKey = { _ in XCTFail("Punctuation must use literal input") }

        // Exercise the same Objective-C handler as the installed recognizer,
        // including suppression of the ordinary tap after a completed hold.
        func hold(_ button: UIButton) throws {
            let installed = try XCTUnwrap(button.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first)
            XCTAssertEqual(installed.minimumPressDuration, 0.4)
            let gesture = SimulatedHold()
            button.addGestureRecognizer(gesture)
            defer { button.removeGestureRecognizer(gesture) }
            gesture.simulatedState = .began
            keyboard.perform(NSSelectorFromString("holdAlternate:"), with: gesture)
            gesture.simulatedState = .ended
            keyboard.perform(NSSelectorFromString("holdAlternate:"), with: gesture)
            button.sendActions(for: .touchUpInside)
        }

        for mode in [Language.korean, .english] {
            keyboard.update(mode: mode, automatic: true)
            hyphen.sendActions(for: .touchUpInside)
            try hold(hyphen)
            hyphen.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(inserted, ["-", "→", "-", "-", "→", "-"])
        inserted.removeAll()
        let punctuationAlternates: [(String, Character)] = [(".", ","), ("?", "!")]
        for (title, alternate) in punctuationAlternates {
            let key = try XCTUnwrap(keys.first { $0.title(for: .normal) == title })
            XCTAssertEqual(key.accessibilityHint, "길게 눌러 \(alternate) 입력")
            try hold(key)
        }
        try hold(space)
        XCTAssertEqual(inserted, [",", "!", "\t"])
    }

    @MainActor func testNumberShiftAndPunctuationAtNarrowWidth() {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        keyboard.update(mode: .korean, automatic: true)
        keyboard.layoutIfNeeded()
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { child in
                (child as? UIButton).map { [$0] } ?? buttons(in: child)
            }
        }
        let keys = buttons(in: keyboard)
        var inserted: [Character] = []
        keyboard.onLiteral = { inserted.append($0) }
        let shift = keys.first { $0.title(for: .normal) == "⇧" }!
        let one = keys.first { $0.accessibilityLabel?.hasPrefix("숫자 1,") == true }!
        shift.sendActions(for: .touchDown)
        shift.sendActions(for: .touchUpInside)
        one.sendActions(for: .touchUpInside)
        one.sendActions(for: .touchUpInside)
        for symbol in [".", "?"] {
            let key = keys.first { $0.title(for: .normal) == symbol }!
            let frame = key.convert(key.bounds, to: keyboard)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, 320)
            key.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(inserted, ["!", "1", ".", "?"])
    }

    @MainActor func testSymbolModeRemapsTildeAndPlusWithoutChangingBottomPunctuation() throws {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        keyboard.update(mode: .korean, automatic: true)
        keyboard.layoutIfNeeded()
        let keys = suggestionButtons(in: keyboard)
        let symbolToggle = try XCTUnwrap(keys.first { $0.title(for: .normal) == "※" })
        let bottomPeriod = try XCTUnwrap(keys.first { $0.title(for: .normal) == "." })
        let bottomQuestion = try XCTUnwrap(keys.first { $0.title(for: .normal) == "?" })
        let positions = Array("1234567890qwertyuiopasdfghjkl;zxcvbnm,./")
        let originalValues = Array("1234567890-/:;()₩&@.,?!'\"[]{}+=_*%<>\\|~`#")
        let symbolValues = Array("1234567890-/:;()₩&@~,+!'\"[]{}+=_*%<>\\|~`#")
        let originalPeriodIndex = try XCTUnwrap(originalValues.firstIndex(of: "."))
        let originalCommaIndex = try XCTUnwrap(originalValues.firstIndex(of: ","))
        let originalQuestionAfterCommaIndex = originalCommaIndex + 1
        XCTAssertLessThan(originalQuestionAfterCommaIndex, originalValues.count)
        XCTAssertEqual(originalValues[originalQuestionAfterCommaIndex], "?")
        let originalTildeIndex = try XCTUnwrap(originalValues.firstIndex(of: "~"))
        // Only the period slot and the key after comma change. Comma and the
        // original "~" stay "~"/"," in the map.
        let changed = originalValues.indices.filter { originalValues[$0] != symbolValues[$0] }
        XCTAssertEqual(changed, [originalPeriodIndex, originalQuestionAfterCommaIndex])
        XCTAssertEqual(symbolValues[originalPeriodIndex], "~")
        XCTAssertEqual(symbolValues[originalCommaIndex], ",")
        XCTAssertEqual(symbolValues[originalQuestionAfterCommaIndex], "+")
        XCTAssertEqual(symbolValues[originalTildeIndex], "~")

        let letters = Set("qwertyuiopasdfghjklzxcvbnm")
        let digits = Set("1234567890")
        // Before symbol mode, letter keys read "한글 …, 영문 q, 현재 …" and
        // number keys read "숫자 1, Shift …". Symbol mode replaces a letter
        // key's label with the glyph alone. ";,. /" are map slots, not keys.
        func key(at index: Int) throws -> UIButton {
            let position = positions[index]
            let match = keys.first { button in
                guard let label = button.accessibilityLabel else { return false }
                if letters.contains(position) { return label.contains("영문 \(position),") }
                if digits.contains(position) { return label.hasPrefix("숫자 \(position),") }
                return false
            }
            return try XCTUnwrap(match, "No symbol-layer key for position \(position)")
        }

        let periodMappedKey = try key(at: originalPeriodIndex)
        let commaMappedKey = try key(at: originalCommaIndex)
        let questionAfterCommaKey = try key(at: originalQuestionAfterCommaIndex)
        let originalTildePosition = positions[originalTildeIndex]
        XCTAssertFalse(letters.contains(originalTildePosition) || digits.contains(originalTildePosition))
        let originalTildeKey = keys.first { button in
            guard let label = button.accessibilityLabel else { return false }
            return label.contains("영문 \(originalTildePosition),") || label.hasPrefix("숫자 \(originalTildePosition),")
        }

        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let previewBubble = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "keyPreview" })
        let previewText = try XCTUnwrap(descendants(previewBubble).first { $0.accessibilityIdentifier == "keyPreviewText" } as? UILabel)
        XCTAssertEqual(previewBubble.accessibilityIdentifier, "keyPreview")
        XCTAssertEqual(previewText.accessibilityIdentifier, "keyPreviewText")
        var inserted: [Character] = []
        keyboard.onLiteral = { inserted.append($0) }
        keyboard.onKey = { _ in XCTFail("Symbols and punctuation should use literal input") }

        symbolToggle.sendActions(for: .touchUpInside)
        XCTAssertEqual(periodMappedKey.accessibilityLabel, "~")
        XCTAssertEqual(commaMappedKey.accessibilityLabel, ",")
        XCTAssertEqual(questionAfterCommaKey.accessibilityLabel, "+")
        // The original "~" is the QWERTY "." map slot. That slot is not a letter
        // or number key, so it has no "영문 ." / "숫자 ." label. The fixed
        // bottom "." stays "." and is not that slot. When a key does exist
        // for the slot, symbol mode must still show "~".
        if let originalTildeKey {
            XCTAssertEqual(originalTildeKey.accessibilityLabel, "~")
        }
        XCTAssertFalse(bottomPeriod === periodMappedKey)
        XCTAssertEqual(bottomPeriod.title(for: .normal), ".")
        XCTAssertEqual(bottomQuestion.title(for: .normal), "?")

        periodMappedKey.sendActions(for: .touchDown)
        XCTAssertEqual(previewText.text, "~")
        XCTAssertTrue(inserted.isEmpty)
        periodMappedKey.sendActions(for: .touchUpInside)
        XCTAssertEqual(inserted, ["~"])
        inserted.removeAll()

        // A long press on symbol-layer keys has no alternate and must not
        // suppress or duplicate the eventual tap emission.
        func holdThenTap(_ button: UIButton) throws {
            let gesture = SimulatedHold()
            button.addGestureRecognizer(gesture)
            defer { button.removeGestureRecognizer(gesture) }
            gesture.simulatedState = .began
            keyboard.perform(NSSelectorFromString("holdAlternate:"), with: gesture)
            gesture.simulatedState = .ended
            keyboard.perform(NSSelectorFromString("holdAlternate:"), with: gesture)
            button.sendActions(for: .touchUpInside)
        }
        try holdThenTap(questionAfterCommaKey)
        XCTAssertEqual(inserted, ["+"])
        inserted.removeAll()

        bottomPeriod.sendActions(for: .touchUpInside)
        bottomQuestion.sendActions(for: .touchUpInside)
        XCTAssertEqual(inserted, [".", "?"])
    }
}

final class PresentedKeyboardTests: XCTestCase {
    @MainActor func testPresentedAppKeyboardFitsVisibleWindow() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        let editor = HardwareTextView(frame: CGRect(x: 20, y: 100, width: 300, height: 100))
        editor.hardwareKeyboardIsConnected = { false }
        editor.setHardwareKeyboardConnected(false)
        controller.view.addSubview(editor)
        window.makeKeyAndVisible()
        defer { editor.resignFirstResponder(); window.isHidden = true }
        editor.becomeFirstResponder()
        try await Task.sleep(for: .seconds(3))
        let input = editor.inputView as! TouchKeyboardInputView
        let keyboard = input.keyboard
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
        }
        let space = buttons(in: keyboard).first { $0.title(for: .normal) == "간격" }!
        let keyboardWindow = input.window!
        let keyFrame = space.convert(space.bounds, to: keyboardWindow)
        XCTAssertEqual(space.bounds.height, 42, accuracy: 0.1)
        XCTAssertLessThanOrEqual(keyFrame.maxY, keyboardWindow.bounds.height - keyboardWindow.safeAreaInsets.bottom)
    }
}

final class TerminalInputTests: XCTestCase {
    func testKoreanStaysLocalUntilCommitAndDeletesJamo() {
        let input = TerminalInput()
        var output = ""
        input.send = { output += $0 }
        for character in "kfx" { input.input(character) }
        XCTAssertEqual(input.pending, "각")
        XCTAssertEqual(output, "")
        input.backspace()
        XCTAssertEqual(input.pending, "가")
        input.flush()
        XCTAssertEqual(output, "가")
        XCTAssertEqual(input.pending, "")
        input.backspace()
        XCTAssertEqual(output, "가\u{7f}")
    }
    func testEnglishIsImmediateAndBoundaryNeverRewritesRemote() {
        let input = TerminalInput(mode: .english)
        var output = ""
        input.send = { output += $0 }
        for character in "ls -la" { input.input(character) }
        XCTAssertEqual(output, "ls -la")
        XCTAssertEqual(input.pending, "")
        input.configure(mode: .korean, automatic: false)
        for character in "kf " { input.input(character) }
        XCTAssertEqual(output, "ls -la가 ")
        input.flush()
        XCTAssertEqual(output, "ls -la가 ")
    }
    func testToggleChangesOnlyUnsentWord() {
        let input = TerminalInput()
        var output = ""
        input.send = { output += $0 }
        for character in "kf" { input.input(character) }
        input.toggle()
        XCTAssertEqual(input.pending, "kf")
        XCTAssertEqual(output, "")
        input.flush()
        XCTAssertEqual(output, "kf")
    }
}

@MainActor
final class TerminalKeyboardTests: XCTestCase {
    func testPhysical390MappingAndControlBoundary() {
        let model = TerminalModel()
        model.status = "연결됨"
        let terminal = SetoTerminal(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        terminal.model = model
        for usage in [14, 9, 27] { XCTAssertTrue(terminal.handleKey(usage: usage)) }
        XCTAssertEqual(model.pending, "각")
        XCTAssertTrue(terminal.handleKey(usage: 42))
        XCTAssertEqual(model.pending, "가")
        XCTAssertFalse(terminal.handleKey(usage: 224, flags: .control))
        XCTAssertEqual(model.pending, "가")
        XCTAssertFalse(terminal.handleKey(usage: 6, flags: .control))
        XCTAssertEqual(model.pending, "")
    }
    func testShiftSpaceAndFocusStayInKeyboardHost() {
        let model = TerminalModel()
        model.status = "연결됨"
        let terminal = SetoTerminal(frame: .zero)
        terminal.model = model
        let host = TerminalKeyboardHost(terminal: terminal)
        let controller = UIViewController()
        controller.view = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { host.resignFirstResponder(); window.isHidden = true }
        XCTAssertTrue(terminal.becomeFirstResponder())
        XCTAssertTrue(host.isFirstResponder)
        XCTAssertFalse(terminal.isFirstResponder)
        for usage in [14, 9] { terminal.handleKey(usage: usage) }
        XCTAssertTrue(terminal.handleKey(usage: 44, flags: .shift))
        XCTAssertEqual(model.pending, "kf")
        XCTAssertEqual(model.mode, .english)
    }
    func testDisconnectDiscardsUnsentInput() {
        let model = TerminalModel()
        model.status = "연결됨"
        let terminal = SetoTerminal(frame: .zero)
        terminal.model = model
        for usage in [14, 9, 27, 14, 9] { terminal.handleKey(usage: usage) }
        XCTAssertFalse(model.pending.isEmpty)
        terminal.disconnect()
        XCTAssertEqual(model.pending, "")
        XCTAssertEqual(model.status, "연결 종료")
    }
}

final class TerminalAutomaticInputTests: XCTestCase {
    func testAutomaticEnglishIsBufferedAndCommittedOnSpace() {
        let input = TerminalInput(lexicon: TerminalInput.bundledLexicon, automatic: true)
        var output = ""
        input.send = { output += $0 }
        for key in "hello" { input.input(key) }
        XCTAssertEqual(output, "")
        input.input(" ")
        XCTAssertEqual(output, "hello ")
        XCTAssertEqual(input.mode, .english)
        XCTAssertTrue(input.automatic)
    }
    func testExplicitCommitResolvesAutomaticWordWithoutExtraSpace() {
        let input = TerminalInput(lexicon: TerminalInput.bundledLexicon, automatic: true)
        var output = ""
        input.send = { output += $0 }
        for key in "hello" { input.input(key) }
        input.flush()
        XCTAssertEqual(output, "hello")
        XCTAssertEqual(input.pending, "")
        input.flush()
        XCTAssertEqual(output, "hello")
        XCTAssertFalse(output.contains("\u{7f}"))
    }
    @MainActor func testBundledD2CodingAndKoreanCellWidths() throws {
        let font = try XCTUnwrap(UIFont(name: "D2Coding", size: 18))
        XCTAssertNotNil(UIFont(name: "D2CodingBold", size: 18))
        let latin = ("M" as NSString).size(withAttributes: [.font: font]).width
        let korean = ("한" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(korean, latin * 2, accuracy: 0.1)
        let terminal = SetoTerminal(frame: .zero)
        XCTAssertEqual(terminal.font.fontName, font.fontName)
        XCTAssertEqual(terminal.font.pointSize, 18)
    }
}

final class IOSHardwareLayoutTests: XCTestCase {
    @MainActor func testEditorSupportsAllLayoutsAndPreservesSelectionOnReset() {
        for (layout, usages, expected) in [
            (KeyboardLayout.dubeol, [21, 14, 21], "각"),
            (.sebeol390, [14, 9], "가"),
            (.sebeolFinal, [14, 9], "가")
        ] {
            let editor = HardwareTextView()
            editor.configure(automatic: false, mode: .korean, layout: layout)
            for usage in usages { editor.handleKey(usage: usage) }
            if layout != .dubeol { editor.handleKey(usage: 30, flags: .shift) }
            XCTAssertEqual(editor.text, layout == .sebeolFinal ? "갂" : layout == .sebeol390 ? "갖" : expected)
            editor.resetSession()
            XCTAssertEqual(editor.session.layout, layout)
        }
    }
    func testTerminalFinalLayoutSurvivesCommitAndSwitch() {
        let input = TerminalInput(layout: .sebeolFinal)
        var output = ""
        input.send = { output += $0 }
        for key in "kf!" { input.input(key) }
        XCTAssertEqual(input.pending, "갂")
        input.flush()
        XCTAssertEqual(output, "갂")
        XCTAssertEqual(input.layout, .sebeolFinal)
        input.configure(mode: .korean, automatic: false, layout: .dubeol)
        for key in "rkr" { input.input(key) }
        XCTAssertEqual(input.pending, "각")
        XCTAssertEqual(output, "갂")
        input.discard()
        XCTAssertEqual(input.layout, .dubeol)
    }
}

@MainActor
final class TerminalLifecycleTests: XCTestCase {
    func testClosedTerminalReleasesUIResources() {
        weak var releasedTerminal: SetoTerminal?
        weak var releasedHost: TerminalKeyboardHost?
        autoreleasepool {
            let terminal = SetoTerminal(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            let host = TerminalKeyboardHost(terminal: terminal)
            releasedTerminal = terminal
            releasedHost = host
            terminal.disconnect()
            host.stopAllInput()
        }
        XCTAssertNil(releasedHost)
        XCTAssertNil(releasedTerminal)
    }
}

@MainActor
final class SSHTabTests: XCTestCase {
    func testSwitchKeepsIndependentModelsAndPendingText() throws {
        let workspace = SSHTabs()
        let first = try XCTUnwrap(workspace.tabs.first)
        first.model.pending = "첫 작업"
        workspace.add()
        let second = try XCTUnwrap(workspace.tabs.last)
        second.model.pending = "둘째 작업"
        XCTAssertFalse(first.model === second.model)
        XCTAssertFalse(first.files === second.files)
        workspace.selected = first.id
        XCTAssertEqual(first.model.pending, "첫 작업")
        XCTAssertEqual(second.model.pending, "둘째 작업")
        workspace.remove(second.id)
        XCTAssertEqual(workspace.selected, first.id)
        XCTAssertEqual(first.model.pending, "첫 작업")
    }
    func testClosingTabReleasesItsRetainedTerminalAndKeepsNeighbor() throws {
        let workspace = SSHTabs()
        let first = try XCTUnwrap(workspace.tabs.first)
        weak var releasedHost: TerminalKeyboardHost?
        autoreleasepool {
            let terminal = SetoTerminal(frame: .zero)
            terminal.model = first.model
            first.model.terminal = terminal
            let host = TerminalKeyboardHost(terminal: terminal)
            first.model.retainedHost = host
            releasedHost = host
        }
        XCTAssertNotNil(releasedHost)
        workspace.add()
        let neighbor = workspace.selected
        workspace.remove(first.id)
        XCTAssertNil(releasedHost)
        XCTAssertEqual(workspace.selected, neighbor)
        XCTAssertEqual(workspace.tabs.count, 1)
    }
    func testClosingLastTabCreatesAnEmptyConnectionTab() throws {
        let workspace = SSHTabs()
        let old = try XCTUnwrap(workspace.selected)
        workspace.remove(old)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.selected, old)
        XCTAssertEqual(workspace.tabs[0].model.status, "연결 전")
    }
}

@MainActor
final class SSHTabDraftTests: XCTestCase {
    func testTwoTabsDoNotOverwriteEachOthersLocalDrafts() throws {
        let suite = "SSHTabDraftTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SSHRemoteEditor(defaults: defaults)
        let second = SSHRemoteEditor(defaults: defaults)
        for (editor, path) in [(first, "/first.md"), (second, "/second.md")] {
            editor.bind(origin: "user@server:22", session: path, send: { _ in })
            editor.receive(.init(session: path, type: "ready"))
            editor.receive(.init(session: path, type: "open", path: path, content: "original", version: "v1"))
            editor.update("changed")
        }
        first.disconnected()
        second.disconnected()
        XCTAssertEqual(Set(SSHRemoteEditor(defaults: defaults).drafts.map(\.path)), ["/first.md", "/second.md"])
        first.close(discardDraft: true)
        XCTAssertEqual(SSHRemoteEditor(defaults: defaults).drafts.map(\.path), ["/second.md"])
    }
}

@MainActor
final class SSHTabShortcutTests: XCTestCase {
    func testCommandShiftBracketsSwitchWithoutCommittingPendingInput() throws {
        let workspace = SSHTabs()
        let first = try XCTUnwrap(workspace.tabs.first)
        workspace.add()
        let second = try XCTUnwrap(workspace.tabs.last)
        workspace.selected = first.id
        let terminal = SetoTerminal(frame: .zero)
        terminal.model = first.model
        first.model.status = "연결됨"
        terminal.handleKey(usage: 14)
        terminal.handleKey(usage: 9)
        let pending = first.model.pending
        XCTAssertTrue(terminal.handleKey(usage: 48, flags: [.command, .shift]))
        XCTAssertEqual(workspace.selected, second.id)
        XCTAssertEqual(first.model.pending, pending)
        XCTAssertTrue(terminal.handleKey(usage: 47, flags: [.command, .shift]))
        XCTAssertEqual(workspace.selected, first.id)
        workspace.move(-1)
        XCTAssertEqual(workspace.selected, second.id)
        workspace.move(1)
        XCTAssertEqual(workspace.selected, first.id)
    }
    func testSingleTabAndPrioritizedKeyCommands() throws {
        let workspace = SSHTabs()
        let selected = workspace.selected
        workspace.move(-1)
        workspace.move(1)
        XCTAssertEqual(workspace.selected, selected)
        let host = TerminalKeyboardHost(terminal: SetoTerminal(frame: .zero))
        let commands = try XCTUnwrap(host.keyCommands)
        for input in ["[", "]"] {
            let command = try XCTUnwrap(commands.first { $0.input == input })
            XCTAssertEqual(command.modifierFlags, [.command, .shift])
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        }
    }
}

final class BackspaceRepeatTests: XCTestCase {
    func testHeldBackspaceMatchesSystemKeyboardCadence() {
        var repeatState = BackspaceRepeat()
        repeatState.begin(at: 1_000)
        XCTAssertEqual(repeatState.dueActions(at: 1_000.49), [])

        var actions: [BackspaceRepeat.Action] = []
        var gaps: [TimeInterval] = []
        var previous = 1_000.0
        for _ in 0..<23 {
            let deadline = try? XCTUnwrap(repeatState.nextDeadline())
            guard let deadline else { XCTFail("repeat ended early"); return }
            gaps.append(deadline - previous)
            previous = deadline
            actions.append(contentsOf: repeatState.dueActions(at: deadline))
        }
        XCTAssertEqual(actions.prefix(20).filter { $0 == .character }.count, 20)
        XCTAssertEqual(actions.dropFirst(20).prefix(3).filter { $0 == .word }.count, 3)
        XCTAssertEqual(gaps[0], 0.5, accuracy: 0.000_001)
        for gap in gaps[1...20] {
            XCTAssertEqual(gap, 0.1, accuracy: 0.000_001)
        }
        XCTAssertEqual(gaps[21], 0.35, accuracy: 0.000_001)
        XCTAssertEqual(gaps[22], 0.35, accuracy: 0.000_001)

        repeatState.end()
        XCTAssertEqual(repeatState.dueActions(at: previous + 10), [])
        XCTAssertNil(repeatState.nextDeadline())
    }

    func testWordWaveTakesWhitespacePunctuationAndHyphenBoundary() {
        XCTAssertEqual(WordDeletion.unit(in: "delta  "), "delta  ")
        XCTAssertEqual(WordDeletion.unit(in: "charlie. "), "charlie. ")
        XCTAssertEqual(WordDeletion.units(in: "foxtrot-golf", count: 2), ["golf", "foxtrot-"])
        XCTAssertEqual(WordDeletion.units(in: "twelve ZZZZ", count: 2), ["ZZZZ", "twelve "])
        XCTAssertEqual(WordDeletion.units(in: "ab cd ef ", count: 2), ["ef ", "cd "])
        XCTAssertEqual(WordDeletion.unit(in: "안녕 하세요"), "하세요")
        XCTAssertEqual(WordDeletion.units(in: "안녕 하세요 ", count: 2), ["하세요 ", "안녕 "])
        XCTAssertEqual(WordDeletion.unit(in: ""), "")

        let owned = WordDeletion.plan(contextBefore: "ab cd ef ", sessionDocument: "ab cd ef ", composing: false, selection: false)
        XCTAssertFalse(owned.single)
        XCTAssertEqual(owned.sessionBackspaces, "cd ef ".count)
        XCTAssertEqual(owned.hostBackspaces, 0)

        let tail = WordDeletion.plan(contextBefore: "ab cd ef ", sessionDocument: "ef ", composing: false, selection: false)
        XCTAssertFalse(tail.single)
        XCTAssertEqual(tail.sessionBackspaces, "ef ".count)
        XCTAssertEqual(tail.hostBackspaces, "cd ".count)

        XCTAssertTrue(WordDeletion.plan(contextBefore: "각", sessionDocument: "각", composing: true, selection: false).single)
        XCTAssertTrue(WordDeletion.plan(contextBefore: "abc", sessionDocument: "", composing: false, selection: true).single)
        XCTAssertTrue(WordDeletion.plan(contextBefore: nil, sessionDocument: "secret", composing: false, selection: false).single)
        XCTAssertTrue(WordDeletion.plan(contextBefore: "hello", sessionDocument: "other", composing: false, selection: false).single)
    }

    @MainActor func testPressDeletesOnceAndReleaseAddsNothing() {
        let keyboard = preparedKeyboard()
        var characters = 0
        var words = 0
        keyboard.onDelete = { characters += 1 }
        keyboard.onDeleteWord = { words += 1 }
        let backspace = backspaceKey(in: keyboard)

        backspace.sendActions(for: .touchUpInside)
        XCTAssertEqual(characters, 1)
        XCTAssertEqual(words, 0)

        backspace.sendActions(for: .touchDown)
        backspace.sendActions(for: .touchUpInside)
        XCTAssertEqual(characters, 2)
        XCTAssertEqual(words, 0)
        now += 10
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(characters, 2)
        XCTAssertEqual(words, 0)
    }

    @MainActor func testHoldRepeatsCharactersThenWordsAndStopsWhenEmptyOrCancelled() {
        let keyboard = preparedKeyboard()
        var characters = 0
        var words = 0
        var allow = true
        keyboard.onDelete = { characters += 1 }
        keyboard.onDeleteWord = { words += 1 }
        keyboard.backspaceHasMoreText = { allow }
        let backspace = backspaceKey(in: keyboard)

        backspace.sendActions(for: .touchDown)
        XCTAssertEqual(characters, 1)
        for _ in 0..<BackspaceRepeat.characterRepeatCount {
            now = try! XCTUnwrap(keyboard.backspaceNextDeadline())
            keyboard.advanceBackspaceRepeat()
        }
        XCTAssertEqual(characters, 1 + BackspaceRepeat.characterRepeatCount)
        XCTAssertEqual(words, 0)

        now = try! XCTUnwrap(keyboard.backspaceNextDeadline())
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(words, 1)
        XCTAssertEqual(characters, 21)

        backspace.sendActions(for: .touchCancel)
        now += 10
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(words, 1)
        XCTAssertEqual(characters, 21)

        allow = true
        backspace.sendActions(for: .touchDown)
        XCTAssertEqual(characters, 22)
        allow = false
        now = try! XCTUnwrap(keyboard.backspaceNextDeadline())
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(characters, 23)
        backspace.sendActions(for: .touchUpInside)
        XCTAssertEqual(characters, 23)
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(characters, 23)
    }

    @MainActor func testBackspaceHoldDoesNotReplaceOtherLongPresses() {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        let keys = buttons(in: keyboard)
        let backspace = backspaceKey(in: keyboard)
        XCTAssertNil(backspace.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })
        for title in ["간격", "q"] {
            let key: UIButton
            if title == "q" {
                key = try! XCTUnwrap(keys.first { $0.accessibilityLabel?.contains("영문 q,") == true })
            } else {
                key = try! XCTUnwrap(keys.first { $0.title(for: .normal) == title })
            }
            let hold = try! XCTUnwrap(key.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer } as? UILongPressGestureRecognizer)
            XCTAssertEqual(hold.minimumPressDuration, 0.4)
        }
        let hyphen = try! XCTUnwrap(keys.first { $0.accessibilityLabel == "하이픈 입력" })
        XCTAssertEqual(hyphen.accessibilityHint, "길게 눌러 → 입력")
        XCTAssertNotNil(hyphen.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })
    }

    @MainActor func testCompositionHoldDeletesOneJamoAndATapAfterSpaceDeletesOneCharacter() {
        let editor = HardwareTextView()
        editor.hardwareKeyboardIsConnected = { false }
        editor.setHardwareKeyboardConnected(false)
        editor.configure(automatic: false, mode: .korean)
        let keyboard = (editor.inputView as! TouchKeyboardInputView).keyboard
        keyboard.backspaceRepeatUsesTimer = false
        keyboard.backspaceClock = { self.now }
        type("rkr", on: editor)
        XCTAssertEqual(editor.text, "각")

        let backspace = backspaceKey(in: keyboard)
        backspace.sendActions(for: .touchDown)
        backspace.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, "가")
        now += 10
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(editor.text, "가")

        type("r", on: editor)
        XCTAssertEqual(editor.text, "각")
        keyboard.performBackspaceRepeatAction(.word)
        XCTAssertEqual(editor.text, "가")

        backspace.sendActions(for: .touchDown)
        now = keyboard.backspaceNextDeadline() ?? now
        keyboard.advanceBackspaceRepeat()
        backspace.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, "")
        now += 10
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(editor.text, "")
    }

    @MainActor func testSingleTapAfterCommittedWordDoesNotDeleteTheWord() {
        let editor = HardwareTextView()
        editor.hardwareKeyboardIsConnected = { false }
        editor.setHardwareKeyboardConnected(false)
        editor.configure(automatic: true, mode: .english)
        let keyboard = (editor.inputView as! TouchKeyboardInputView).keyboard
        keyboard.backspaceRepeatUsesTimer = false
        keyboard.backspaceClock = { self.now }
        type("gksrmf ", on: editor)
        let committed = editor.text ?? ""
        XCTAssertTrue(committed.hasSuffix(" "), "space should commit the word, got \(committed)")
        backspaceKey(in: keyboard).sendActions(for: .touchDown)
        backspaceKey(in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, String(committed.dropLast()))
        now += 10
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(editor.text, String(committed.dropLast()))
    }

    @MainActor func testWordWaveDeletesTwoCommittedWords() {
        let editor = HardwareTextView()
        editor.hardwareKeyboardIsConnected = { false }
        editor.setHardwareKeyboardConnected(false)
        editor.configure(automatic: false, mode: .english)
        let keyboard = (editor.inputView as! TouchKeyboardInputView).keyboard
        type("ab cd ef ", on: editor)
        XCTAssertEqual(editor.text, "ab cd ef ")
        keyboard.performBackspaceRepeatAction(.word)
        XCTAssertEqual(editor.text, "ab ")
    }

    @MainActor func testPhraseHoldDeletesJamoThenStops() {
        let previous = UserDefaults.standard.object(forKey: "quickPhrases")
        defer { UserDefaults.standard.set(previous, forKey: "quickPhrases") }
        UserDefaults.standard.removeObject(forKey: "quickPhrases")
        let keyboard = preparedKeyboard()
        keyboard.update(mode: .korean, automatic: false)
        buttons(in: keyboard).first { $0.accessibilityLabel == "문구 등록" }!.sendActions(for: .touchUpInside)
        type("rkr", on: keyboard)
        XCTAssertEqual(draft(in: keyboard), "각")
        keyboard.performBackspaceRepeatAction(.word)
        XCTAssertEqual(draft(in: keyboard), "가")

        let backspace = backspaceKey(in: keyboard)
        backspace.sendActions(for: .touchDown)
        XCTAssertEqual(draft(in: keyboard), "ㄱ")
        now = try! XCTUnwrap(keyboard.backspaceNextDeadline())
        keyboard.advanceBackspaceRepeat()
        backspace.sendActions(for: .touchUpInside)
        XCTAssertEqual(draft(in: keyboard), "저장할 문구를 입력하세요")
        now += 10
        keyboard.advanceBackspaceRepeat()
        XCTAssertEqual(draft(in: keyboard), "저장할 문구를 입력하세요")
    }

    @MainActor func testPhraseWordWaveDeletesTwoCommittedWords() {
        let previous = UserDefaults.standard.object(forKey: "quickPhrases")
        defer { UserDefaults.standard.set(previous, forKey: "quickPhrases") }
        UserDefaults.standard.removeObject(forKey: "quickPhrases")
        let keyboard = preparedKeyboard()
        keyboard.update(mode: .english, automatic: false)
        buttons(in: keyboard).first { $0.accessibilityLabel == "문구 등록" }!.sendActions(for: .touchUpInside)
        type("ab cd ef ", on: keyboard)
        XCTAssertEqual(draft(in: keyboard), "ab cd ef ")
        keyboard.performBackspaceRepeatAction(.word)
        XCTAssertEqual(draft(in: keyboard), "ab ")
    }

    private var now: TimeInterval = 0

    @MainActor private func preparedKeyboard() -> KeyboardView {
        now = 0
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        keyboard.backspaceRepeatUsesTimer = false
        keyboard.backspaceClock = { self.now }
        return keyboard
    }

    @MainActor private func backspaceKey(in keyboard: KeyboardView) -> UIButton {
        buttons(in: keyboard).first { $0.accessibilityLabel == "삭제" }!
    }

    @MainActor private func buttons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
    }

    @MainActor private func draft(in keyboard: KeyboardView) -> String? {
        func labels(in view: UIView) -> [UILabel] {
            view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
        }
        return labels(in: keyboard).first { $0.accessibilityIdentifier == "phraseDraft" }?.text
    }

    @MainActor private func type(_ spelling: String, on editor: HardwareTextView) {
        type(spelling, on: (editor.inputView as! TouchKeyboardInputView).keyboard)
    }

    @MainActor private func type(_ spelling: String, on keyboard: KeyboardView) {
        let keys = buttons(in: keyboard)
        for character in spelling {
            if character == " " {
                keys.first { $0.title(for: .normal) == "간격" }!.sendActions(for: .touchUpInside)
            } else {
                keys.first { $0.accessibilityLabel?.contains("영문 \(character),") == true }!.sendActions(for: .touchUpInside)
            }
        }
    }
}

/// Long-press of ※ re-reads the open word in the other language. Tap still
/// toggles the symbol layer, and the other holds keep their own actions.
final class SymbolLongPressTests: XCTestCase {
    @MainActor func testLongPressConvertsTheOpenWordInBothDirections() {
        let korean = makeEditor(automatic: false, mode: Language.korean)
        type("skt", on: korean)
        XCTAssertEqual(korean.text, "낫")
        XCTAssertEqual(korean.session.preedit, "낫")
        let koreanKeys = keyboardView(of: korean)
        let q = letter("q", in: koreanKeys)
        longPressSymbol(on: koreanKeys)
        XCTAssertEqual(korean.text, "skt")
        XCTAssertEqual(korean.session.preedit, "")
        XCTAssertEqual(korean.session.mode, Language.english)
        XCTAssertTrue(q.accessibilityLabel?.contains("현재 q") == true)
        // The keys are still the open word, so another hold flips it back
        // and the syllable is composable again.
        longPressSymbol(on: koreanKeys)
        XCTAssertEqual(korean.text, "낫")
        XCTAssertEqual(korean.session.mode, Language.korean)
        XCTAssertEqual(korean.session.preedit, "낫")
        tapBackspace(korean)
        XCTAssertEqual(korean.text, "나")
        XCTAssertEqual(korean.session.preedit, "나")

        let english = makeEditor(automatic: false, mode: Language.english)
        type("skt", on: english)
        XCTAssertEqual(english.text, "skt")
        XCTAssertEqual(english.session.preedit, "")
        longPressSymbol(on: keyboardView(of: english))
        XCTAssertEqual(english.text, "낫")
        XCTAssertEqual(english.session.mode, Language.korean)
        XCTAssertEqual(english.session.preedit, "낫")
        tapBackspace(english)
        XCTAssertEqual(english.text, "나")
    }

    @MainActor func testLongPressIncludesPartialSyllableAndLeavesEarlierText() {
        let editor = makeEditor(automatic: false, mode: Language.korean)
        editor.text = "앞 "
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.resetSession()
        type("sk", on: editor)
        XCTAssertEqual(editor.text, "앞 나")
        XCTAssertEqual(editor.session.preedit, "나")
        longPressSymbol(on: keyboardView(of: editor))
        XCTAssertEqual(editor.text, "앞 sk")
        XCTAssertEqual(editor.session.preedit, "")
        XCTAssertEqual(editor.session.mode, Language.english)
        tapBackspace(editor)
        XCTAssertEqual(editor.text, "앞 s")
    }

    @MainActor func testNothingOpenOnlySwitchesMode() {
        let editor = makeEditor(automatic: false, mode: Language.korean)
        longPressSymbol(on: keyboardView(of: editor))
        XCTAssertEqual(editor.text, "")
        XCTAssertEqual(editor.session.mode, Language.english)
        longPressSymbol(on: keyboardView(of: editor))
        XCTAssertEqual(editor.session.mode, Language.korean)

        let committed = makeEditor(automatic: true, mode: Language.korean)
        type("hello ", on: committed)
        XCTAssertEqual(committed.text, "hello ")
        XCTAssertEqual(committed.session.mode, Language.english)
        longPressSymbol(on: keyboardView(of: committed))
        XCTAssertEqual(committed.text, "hello ")
        XCTAssertEqual(committed.session.mode, Language.korean)
    }

    @MainActor func testConvertedWordIsNotFlippedBackByAutoSwitch() {
        let editor = makeEditor(automatic: true, mode: Language.korean)
        type("dkssud", on: editor)
        XCTAssertEqual(editor.text, "안녕")
        longPressSymbol(on: keyboardView(of: editor))
        XCTAssertEqual(editor.text, "dkssud")
        XCTAssertEqual(editor.session.mode, Language.english)
        type("gktpdy", on: editor)
        XCTAssertEqual(editor.text, "dkssudgktpdy")
        XCTAssertEqual(editor.session.mode, Language.english)

        let english = makeEditor(automatic: true, mode: Language.english)
        type("skt", on: english)
        longPressSymbol(on: keyboardView(of: english))
        XCTAssertEqual(english.text, "낫")
        XCTAssertEqual(english.session.mode, Language.korean)
        type("hello", on: english)
        XCTAssertFalse(english.text?.contains("hello") == true)
        XCTAssertEqual(english.session.mode, Language.korean)
    }

    @MainActor func testSymbolTapStillTogglesAndOtherHoldsStay() throws {
        let editor = makeEditor(automatic: false, mode: Language.korean)
        let keyboard = keyboardView(of: editor)
        let symbol = buttons(in: keyboard).first { $0.title(for: .normal) == "※" }!
        XCTAssertEqual(symbol.accessibilityHint, "길게 눌러 방금 입력한 단어를 반대 자판으로 바꿉니다")
        let hold = try XCTUnwrap(symbol.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first)
        XCTAssertEqual(hold.minimumPressDuration, 0.4)
        let q = letter("q", in: keyboard)
        let backspace = buttons(in: keyboard).first { $0.accessibilityLabel == "삭제" }!
        XCTAssertNil(backspace.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })

        symbol.sendActions(for: .touchUpInside)
        XCTAssertEqual(q.accessibilityLabel, "-")
        symbol.sendActions(for: .touchUpInside)
        XCTAssertTrue(q.accessibilityLabel?.contains("영문 q,") == true)

        type("skt", on: editor)
        longPressSymbol(on: keyboard)
        XCTAssertEqual(editor.text, "skt")
        XCTAssertTrue(q.accessibilityLabel?.contains("영문 q,") == true)
        XCTAssertTrue(q.accessibilityLabel?.contains("현재 q") == true)
        symbol.sendActions(for: .touchUpInside)
        XCTAssertEqual(q.accessibilityLabel, "-")
        symbol.sendActions(for: .touchUpInside)
        XCTAssertTrue(q.accessibilityLabel?.contains("현재 q") == true)

        let shifted = makeEditor(automatic: false, mode: Language.korean)
        longPress(letter("q", in: keyboardView(of: shifted)), on: keyboardView(of: shifted))
        XCTAssertEqual(shifted.text, "ㅃ")

        let hyphen = makeEditor(automatic: false, mode: Language.korean)
        let hyphenKey = buttons(in: keyboardView(of: hyphen)).first { $0.accessibilityLabel == "하이픈 입력" }!
        longPress(hyphenKey, on: keyboardView(of: hyphen))
        XCTAssertEqual(hyphen.text, "→")

        let space = makeEditor(automatic: false, mode: Language.english)
        let spaceKey = buttons(in: keyboardView(of: space)).first { $0.title(for: .normal) == "간격" }!
        longPress(spaceKey, on: keyboardView(of: space))
        XCTAssertEqual(space.text, "\t")

        let deletion = makeEditor(automatic: false, mode: Language.english)
        keyboardView(of: deletion).backspaceRepeatUsesTimer = false
        type("ab", on: deletion)
        let deleteKey = buttons(in: keyboardView(of: deletion)).first { $0.accessibilityLabel == "삭제" }!
        deleteKey.sendActions(for: .touchDown)
        deleteKey.sendActions(for: .touchUpInside)
        XCTAssertEqual(deletion.text, "a")
    }

    @MainActor func testPhraseDraftConvertsWithoutTouchingSymbolMode() {
        let previous = UserDefaults.standard.object(forKey: "quickPhrases")
        defer { UserDefaults.standard.set(previous, forKey: "quickPhrases") }
        UserDefaults.standard.removeObject(forKey: "quickPhrases")
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardView.preferredHeight))
        buttons(in: keyboard).first { $0.accessibilityLabel == "문구 등록" }!.sendActions(for: .touchUpInside)
        longPressSymbol(on: keyboard)
        XCTAssertEqual(draft(in: keyboard), "저장할 문구를 입력하세요")
        XCTAssertTrue(letter("q", in: keyboard).accessibilityLabel?.contains("현재 q") == true)
        type("skt", on: keyboard)
        XCTAssertEqual(draft(in: keyboard), "skt")
        longPressSymbol(on: keyboard)
        XCTAssertEqual(draft(in: keyboard), "낫")
        XCTAssertTrue(letter("q", in: keyboard).accessibilityLabel?.contains("현재 ㅂ") == true)
        XCTAssertEqual(buttons(in: keyboard).first { $0.title(for: .normal) == "※" }?.accessibilityLabel, "기호 자판 전환")
    }

    @MainActor private func makeEditor(automatic: Bool, mode: Language) -> HardwareTextView {
        let editor = HardwareTextView()
        editor.hardwareKeyboardIsConnected = { false }
        editor.setHardwareKeyboardConnected(false)
        editor.configure(automatic: automatic, mode: mode)
        return editor
    }

    @MainActor private func keyboardView(of editor: HardwareTextView) -> KeyboardView {
        (editor.inputView as! TouchKeyboardInputView).keyboard
    }

    @MainActor private func buttons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
    }

    @MainActor private func letter(_ character: Character, in keyboard: KeyboardView) -> UIButton {
        buttons(in: keyboard).first { $0.accessibilityLabel?.contains("영문 \(character),") == true }!
    }

    @MainActor private func type(_ spelling: String, on editor: HardwareTextView) {
        type(spelling, on: keyboardView(of: editor))
    }

    @MainActor private func type(_ spelling: String, on keyboard: KeyboardView) {
        for character in spelling {
            if character == " " {
                buttons(in: keyboard).first { $0.title(for: .normal) == "간격" }!.sendActions(for: .touchUpInside)
            } else {
                letter(character, in: keyboard).sendActions(for: .touchUpInside)
            }
        }
    }

    @MainActor private func tapBackspace(_ editor: HardwareTextView) {
        let keyboard = keyboardView(of: editor)
        keyboard.backspaceRepeatUsesTimer = false
        let backspace = buttons(in: keyboard).first { $0.accessibilityLabel == "삭제" }!
        backspace.sendActions(for: .touchDown)
        backspace.sendActions(for: .touchUpInside)
    }

    @MainActor private func longPressSymbol(on keyboard: KeyboardView) {
        let symbol = buttons(in: keyboard).first { $0.title(for: .normal) == "※" }!
        longPress(symbol, on: keyboard)
    }

    @MainActor private func longPress(_ button: UIButton, on keyboard: KeyboardView) {
        let gesture = SimulatedHold()
        button.addGestureRecognizer(gesture)
        defer { button.removeGestureRecognizer(gesture) }
        gesture.simulatedState = .began
        keyboard.perform(NSSelectorFromString("holdAlternate:"), with: gesture)
        gesture.simulatedState = .ended
        keyboard.perform(NSSelectorFromString("holdAlternate:"), with: gesture)
        button.sendActions(for: .touchUpInside)
    }

    @MainActor private func draft(in keyboard: KeyboardView) -> String? {
        func labels(in view: UIView) -> [UILabel] {
            view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
        }
        return labels(in: keyboard).first { $0.accessibilityIdentifier == "phraseDraft" }?.text
    }

    @MainActor
    private final class SimulatedHold: UILongPressGestureRecognizer {
        var simulatedState: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { simulatedState }
            set { simulatedState = newValue }
        }
    }
}
