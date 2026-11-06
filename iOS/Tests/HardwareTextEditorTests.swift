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
        XCTAssertEqual(view.session.mode, .english)
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
        XCTAssertEqual(view.session.mode, .english)
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

    @MainActor func testBottomKeyWidthsAndDubeolAutoSwitch() {
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
        let letter = keys.first { $0.accessibilityLabel?.contains("영문 q,") == true }!
        let titles = ["#", "↔", "→", ".", "?", "↵"]
        let bottom = titles.map { title in keys.first { $0.title(for: .normal) == title }! }
        // Stack views align frames to display pixels; equal constraints can
        // differ by one pixel after distributing a fractional key width.
        let pixel = 1 / input.traitCollection.displayScale
        for key in bottom { XCTAssertEqual(key.bounds.width, letter.bounds.width, accuracy: pixel + 0.001) }
        let space = keys.first { $0.title(for: .normal) == "간격" }!
        XCTAssertLessThan(bottom[2].convert(bottom[2].bounds, to: keyboard).maxX, space.convert(space.bounds, to: keyboard).minX)
        for character in "world dkssudgktpdy " {
            if character == " " { space.sendActions(for: .touchUpInside) }
            else { keys.first { $0.accessibilityLabel?.contains("영문 \(character),") == true }!.sendActions(for: .touchUpInside) }
        }
        XCTAssertEqual(editor.text, "world 안녕하세요 ")
        bottom[2].sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, "world 안녕하세요 →")
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
