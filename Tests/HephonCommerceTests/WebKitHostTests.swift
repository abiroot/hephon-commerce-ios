import Foundation
@testable import HephonCommerce
import WebKit
import XCTest

/// A real WKWebView: the bridge handler is in before the first load, a message's origin comes
/// from WKSecurityOrigin (port 0 is the default), and host messages reach the page through
/// callAsyncJavaScript with arguments.
@MainActor
final class WebKitHostTests: XCTestCase {
    func testTalksToAPageOnTheChatOrigin() async throws {
        var events: [String] = []
        let controller = HephonAgentController(organization: "suppy-demo", launch: .code("abc"))
        controller.onReady = { [weak controller] _ in
            events.append("ready")
            controller?.focus()
        }
        controller.onOpenProduct = { events.append("echo \($0.itemId)") }
        let webView = controller.webView()
        XCTAssertIdentical(controller.webView(), webView)
        XCTAssertTrue(webView.configuration.allowsInlineMediaPlayback)
        XCTAssertEqual(webView.configuration.mediaTypesRequiringUserActionForPlayback, [])

        // The chat page, stood in by a page at the chat's URL that says ready and answers
        // every host message with an open_product named after its type.
        let ready = try Fixture.page("ready")
        webView.loadHTMLString(
            """
            <script>
            const post = (m) => window.webkit.messageHandlers.HephonBridge.postMessage(JSON.stringify(m));
            window.hephon = { receive(json) {
                const m = JSON.parse(json);
                post({ v: 1, id: "echo-" + m.id, type: "open_product", ts: Date.now(),
                       data: { itemId: m.type, storeId: "branch-7" } });
            } };
            window.webkit.messageHandlers.HephonBridge.postMessage(\(Fixture.json(ready)));
            </script>
            """,
            baseURL: controller.url
        )
        await untilWebKit { events.count == 2 }
        XCTAssertEqual(events, ["ready", "echo focus"])
        XCTAssertEqual(controller.pageState, .loaded)

        controller.dispose()
        var bridge: String?
        evaluate("typeof window.webkit?.messageHandlers?.HephonBridge", in: webView) { bridge = $0 }
        await untilWebKit { bridge != nil }
        XCTAssertEqual(bridge, "undefined")
    }

    /// The completion-handler form: the async one traps when a script returns nothing.
    private func evaluate(_ script: String, in webView: WKWebView, done: @escaping @MainActor (String?) -> Void) {
        webView.evaluateJavaScript(script) { result, _ in done(result as? String) }
    }
}
