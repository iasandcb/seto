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
