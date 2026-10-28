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
            ("cd ../src", "cd ../src", Language.korean),
            ("ls ", "ls ", .korean),
            ("of;", "of;", .english),
            ("don't", "don't", .english),
            ("->", "-3", .korean),
            ("kfx", "각", .korean)
        ] {
            let view = HardwareTextView()
            view.configure(automatic: true, mode: mode)
            var displayedMode = mode
            view.onMode = { displayedMode = $0 }
            let keyboard = try XCTUnwrap(view.inputView as? KeyboardView)
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
        let keyboard = try XCTUnwrap(view.inputView as? KeyboardView)
        keyboard.onKey?("k")
        keyboard.onKey?("f")
        keyboard.onAutoSwitch?()
        XCTAssertFalse(setting)
        XCTAssertFalse(view.session.autoSwitch)
        keyboard.onKey?("x")
        XCTAssertEqual(view.text, "각")
        view.resetSession()
        XCTAssertFalse(view.session.autoSwitch)
    }
}

final class TouchKeyboardLayoutTests: XCTestCase {
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
