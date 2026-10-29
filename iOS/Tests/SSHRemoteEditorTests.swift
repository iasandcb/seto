import XCTest
import UIKit
@testable import Sebeol390

@MainActor
final class SSHRemoteEditorTests: XCTestCase {
    private func makeEditor() -> (SSHRemoteEditor, UserDefaults) {
        let suite = "SSHRemoteEditorTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (SSHRemoteEditor(defaults: defaults), defaults)
    }
    private func attach(_ editor: SSHRemoteEditor, send: @escaping (SSHRemoteMessage) -> Void = { _ in }) {
        editor.bind(origin: "user@example:22", session: "session", send: send)
        editor.receive(.init(session: "session", type: "ready"))
    }
    private func open(_ editor: SSHRemoteEditor, content: String = "original", version: String = "v1") {
        editor.receive(.init(session: "session", type: "open", path: "/project/한 글.md", content: content, version: version))
    }

    func testSessionValidationAndNewFileRequiresExplicitSaveAndAck() {
        let (editor, _) = makeEditor()
        var requests: [SSHRemoteMessage] = []
        attach(editor) { requests.append($0) }
        editor.receive(.init(session: "another", type: "open", path: "/bad", content: "bad", version: "v1"))
        XCTAssertNil(editor.document)
        open(editor, content: "", version: "missing")
        XCTAssertTrue(editor.dirty)
        XCTAssertTrue(requests.isEmpty)
        editor.save()
        XCTAssertTrue(editor.saving)
        XCTAssertEqual(requests.last?.content, "")
        XCTAssertFalse(editor.status.contains("완료"))
        editor.receive(.init(session: "session", type: "saved", id: "wrong", path: editor.document?.path, version: "v2"))
        XCTAssertTrue(editor.saving)
        editor.receive(.init(session: "session", type: "saved", id: requests.last?.id, path: editor.document?.path, version: "v2"))
        XCTAssertFalse(editor.saving)
        XCTAssertFalse(editor.dirty)
        XCTAssertEqual(editor.status, "서버 저장 완료")
    }

    func testTypingDuringSaveKeepsNewDraftUntilMatchingAck() {
        let (editor, defaults) = makeEditor()
        var sent: [SSHRemoteMessage] = []
        attach(editor) { sent.append($0) }
        open(editor)
        editor.update("first")
        editor.save()
        editor.update("second")
        editor.receive(.init(session: "session", type: "saved", id: sent.last?.id, path: editor.document?.path, version: "v2"))
        XCTAssertTrue(editor.dirty)
        XCTAssertEqual(editor.document?.content, "second")
        let recovered = SSHRemoteEditor(defaults: defaults)
        XCTAssertEqual(recovered.drafts.first?.content, "second")
        XCTAssertEqual(recovered.drafts.first?.version, "v2")
        editor.save()
        editor.receive(.init(session: "session", type: "saved", id: sent.last?.id, path: editor.document?.path, version: "v3"))
        XCTAssertFalse(editor.dirty)
        XCTAssertTrue(editor.drafts.isEmpty)
    }

    func testDisconnectCloseAndReopenRestoresDraftWithoutAutomaticWrite() {
        let (editor, defaults) = makeEditor()
        attach(editor)
        open(editor)
        editor.update("각")
        editor.save()
        editor.disconnected()
        XCTAssertFalse(editor.saving)
        XCTAssertEqual(editor.document?.content, "각")
        editor.close()
        XCTAssertNil(editor.document)
        let recovered = SSHRemoteEditor(defaults: defaults)
        var writes = 0
        attach(recovered) { _ in writes += 1 }
        open(recovered)
        XCTAssertEqual(recovered.document?.content, "각")
        XCTAssertFalse(recovered.conflict)
        XCTAssertEqual(writes, 0)
        recovered.close()
    }

    func testConflictKeepsLocalDraftAndDisablesSaveOnReopen() {
        let (editor, defaults) = makeEditor()
        attach(editor)
        open(editor)
        editor.update("mine")
        editor.close()
        let recovered = SSHRemoteEditor(defaults: defaults)
        var writes = 0
        attach(recovered) { _ in writes += 1 }
        open(recovered, content: "external", version: "v2")
        XCTAssertTrue(recovered.conflict)
        XCTAssertEqual(recovered.document?.content, "mine")
        recovered.save()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(recovered.drafts.first?.content, "mine")
    }

    func testLostAckRecoveredWhenServerContentsMatchDraft() {
        let (editor, defaults) = makeEditor()
        attach(editor)
        open(editor)
        editor.update("saved but ack lost")
        editor.disconnected()
        let recovered = SSHRemoteEditor(defaults: defaults)
        attach(recovered)
        open(recovered, content: "saved but ack lost", version: "v2")
        XCTAssertFalse(recovered.dirty)
        XCTAssertFalse(recovered.conflict)
        XCTAssertTrue(recovered.drafts.isEmpty)
    }

    func testUndoToBaselineClearsObsoleteDraft() {
        let (editor, defaults) = makeEditor()
        attach(editor)
        open(editor)
        editor.update("edit")
        XCTAssertEqual(editor.drafts.count, 1)
        editor.update("original")
        editor.close()
        XCTAssertTrue(SSHRemoteEditor(defaults: defaults).drafts.isEmpty)
    }

    func testSaveErrorAndInvalidContentNeverLoseDraft() {
        let (editor, _) = makeEditor()
        var request: SSHRemoteMessage?
        attach(editor) { request = $0 }
        open(editor)
        editor.update("mine")
        editor.save()
        editor.receive(.init(session: "session", type: "error", id: request?.id, code: "conflict", message: "변경됨"))
        XCTAssertTrue(editor.conflict)
        XCTAssertFalse(editor.saving)
        XCTAssertEqual(editor.drafts.first?.content, "mine")
        editor.close()
        open(editor)
        editor.update(String(repeating: "a", count: 1024 * 1024 + 1))
        request = nil
        editor.save()
        XCTAssertNil(request)
        XCTAssertFalse(editor.drafts.isEmpty)
    }

    func testUndoWhileSaveInFlightSurvivesLostAckAndClose() {
        let (editor, defaults) = makeEditor()
        attach(editor)
        open(editor)
        editor.update("sent to server")
        editor.save()
        editor.update("original")
        editor.disconnected()
        editor.close()
        let recovered = SSHRemoteEditor(defaults: defaults)
        XCTAssertEqual(recovered.drafts.first?.content, "original")
        attach(recovered)
        open(recovered, content: "sent to server", version: "v2")
        XCTAssertTrue(recovered.conflict)
        XCTAssertEqual(recovered.document?.content, "original")
    }

    func testEmptyExistingDraftPreviewNeverDeletesDraftOnClose() {
        let (editor, defaults) = makeEditor()
        attach(editor)
        open(editor)
        editor.update("")
        editor.close()
        let recovered = SSHRemoteEditor(defaults: defaults)
        recovered.preview(recovered.drafts[0])
        recovered.close()
        XCTAssertEqual(recovered.drafts.count, 1)
        XCTAssertEqual(recovered.drafts.first?.content, "")
    }

    func testExplicitDiscardAllowsOpeningLatestServerVersion() {
        let (editor, _) = makeEditor()
        attach(editor)
        open(editor)
        editor.update("mine")
        editor.close()
        open(editor, content: "external", version: "v2")
        XCTAssertTrue(editor.conflict)
        editor.close(discardDraft: true)
        XCTAssertTrue(editor.drafts.isEmpty)
        open(editor, content: "external", version: "v2")
        XCTAssertEqual(editor.document?.content, "external")
        XCTAssertFalse(editor.conflict)
    }

    func testEditorTakesFocusAndTerminalCanResumeAfterClose() async {
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
        defer { host.stopAllInput(); terminal.disconnect(); window.isHidden = true }
        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.suspendForEditor()
        XCTAssertFalse(host.isFirstResponder)
        let editor = HardwareTextView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        let acquired = expectation(description: "native editor focus")
        editor.onFocus = { if $0 { acquired.fulfill() } }
        editor.focusOnAttachment = true
        host.addSubview(editor)
        await fulfillment(of: [acquired], timeout: 3)
        XCTAssertTrue(editor.isFirstResponder)
        editor.resignFirstResponder()
        editor.removeFromSuperview()
        XCTAssertTrue(terminal.becomeFirstResponder())
        XCTAssertTrue(host.isFirstResponder)
    }

    func testNative390CompositionIsSavedAsDisplayed() {
        let (editor, _) = makeEditor()
        var request: SSHRemoteMessage?
        attach(editor) { request = $0 }
        open(editor, content: "", version: "missing")
        let textView = HardwareTextView()
        textView.configure(automatic: false, mode: .korean, layout: .sebeol390)
        textView.onText = { editor.update($0) }
        for usage in [14, 9, 27] { textView.handleKey(usage: usage) }
        XCTAssertEqual(editor.document?.content, "각")
        editor.save()
        XCTAssertEqual(request?.type, "save")
        XCTAssertEqual(request?.content, "각")
        editor.disconnected()
    }
}

final class SSHRemoteFramingTests: XCTestCase {
    func testChunksAndMultipleRecordsPreserveUnicodeAndEscapedNewlines() throws {
        let message = SSHRemoteMessage(session: "s", type: "open", path: "/한 글", content: "첫째\n둘째", version: "v1")
        var data = try JSONEncoder().encode(message)
        data.append(10)
        var frames = SSHRemoteFrames()
        var records: [Data] = []
        for byte in data + data { records += try frames.receive(Data([byte])) }
        XCTAssertEqual(records.count, 2)
        for record in records { XCTAssertEqual(try JSONDecoder().decode(SSHRemoteMessage.self, from: record).content, message.content) }
    }
    func testOversizedUnterminatedFrameRejected() {
        var frames = SSHRemoteFrames()
        XCTAssertThrowsError(try frames.receive(Data(repeating: 65, count: SSHRemoteFrames.limit + 1)))
    }
}
