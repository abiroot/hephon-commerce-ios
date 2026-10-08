import UIKit
import WebKit

/// The `WKWebView` behind a `HephonAgentController`: WebKit's delegates translated into the
/// controller's calls. Every decision (origins, navigation, microphone, renewal) is the
/// controller's, where tests reach it.
@MainActor
final class WebKitHost: NSObject, WebViewDriving, WKNavigationDelegate, WKUIDelegate {
    /// The name the page posts to: `window.webkit.messageHandlers.HephonBridge`.
    static let bridgeName = "HephonBridge"

    let webView: WKWebView
    private weak var controller: HephonAgentController?

    init(controller: HephonAgentController) {
        let configuration = WKWebViewConfiguration()
        // Spoken replies play inline and without a tap.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The bridge goes in before the first load. WebKit keeps its handler strongly, so it
        // gets a proxy that does not keep this host (and the controller) alive.
        let proxy = WeakMessageHandler()
        configuration.userContentController.add(proxy, contentWorld: .page, name: Self.bridgeName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.controller = controller
        super.init()
        proxy.host = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = controller.isInspectable
        }
    }

    // MARK: WebViewDriving

    var url: URL? {
        webView.url
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func deliver(_ json: String) async throws {
        // The completion-handler form: the async overlay corrupts the calling task's stack.
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            webView.callAsyncJavaScript(
                "window.hephon && window.hephon.receive(m)",
                arguments: ["m": json],
                in: nil,
                in: .page
            ) { result in
                done.resume(with: result.map { _ in () })
            }
        }
    }

    func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }

    func detach() {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.bridgeName, contentWorld: .page
        )
    }

    // MARK: Bridge in

    func didReceive(_ message: WKScriptMessage) {
        guard let json = message.body as? String else {
            return
        }
        let frame = message.frameInfo
        controller?.receive(json, isMainFrame: frame.isMainFrame, origin: frame.securityOrigin.hephonOrigin)
    }

    // MARK: WKNavigationDelegate

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let controller else {
            decisionHandler(.cancel)
            return
        }
        // No target frame: a target="_blank" link or window.open, never the chat itself.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        decisionHandler(controller.navigate(to: url, isMainFrame: isMainFrame) ? .allow : .cancel)
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        controller?.didStartLoading()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        controller?.didFinishLoading()
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
        controller?.didFailLoading(error)
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        controller?.didFailLoading(error)
    }

    /// iOS ended the page's process (memory pressure): load the chat again.
    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        controller?.reload()
    }

    // MARK: WKUIDelegate

    /// `window.open`: never a second web view; the link is routed like any other.
    func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            _ = controller?.navigate(to: url, isMainFrame: false)
        }
        return nil
    }

    /// Microphone only, from an allowed origin, once the app says yes; never WebKit's prompt.
    func webView(
        _: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame _: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let from = origin.hephonOrigin
        Task { [weak controller] in
            let granted = await controller?.allowsMicrophone(origin: from, microphoneOnly: type == .microphone)
            decisionHandler(granted == true ? .grant : .deny)
        }
    }
}

private extension WKSecurityOrigin {
    /// `scheme://host[:port]`, as the controller's allowed origins are written.
    var hephonOrigin: String? {
        HephonNavigation.origin(scheme: `protocol`, host: host, port: port)
    }
}

/// Holds the host weakly, so the web view's configuration does not keep the chat alive.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var host: WebKitHost?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        host?.didReceive(message)
    }
}
