import Foundation
@testable import HephonCommerce
import XCTest

/// The web view as the controller sees it, recording what the controller does with it.
@MainActor
final class FakeWebView: WebViewDriving {
    var url: URL?
    var loads: [URL] = []
    var delivered: [String] = []
    var opened: [URL] = []
    var detached = false
    /// Runs after each message the controller delivers, like the page would.
    var onDeliver: ((String) -> Void)?

    func load(_ url: URL) {
        loads.append(url)
        self.url = url
    }

    func deliver(_ json: String) async throws {
        delivered.append(json)
        onDeliver?(json)
    }

    func openExternally(_ url: URL) {
        opened.append(url)
    }

    func detach() {
        detached = true
    }

    /// The types of the delivered messages, in order.
    var types: [String] {
        delivered.compactMap { json in
            (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["type"] as? String
        }
    }
}

private let hephon = "https://commerce.hephon.ai"

@MainActor
final class ControllerTests: XCTestCase {
    private var log: [String] = []
    private var sleeps: [TimeInterval] = []
    private var clock = Date(timeIntervalSince1970: 1_791_374_400)
    /// Calls of the app's onSessionExpired.
    private var asked = 0
    /// Whether iOS gave the app the microphone.
    private var osGranted = false

    /// A controller showing the chat in a fake web view, every callback logged.
    private func open(
        launch: HephonLaunch? = .token("token-1"),
        onSessionExpired: (@MainActor () async throws -> String?)? = nil,
        onMicrophonePermission: (@MainActor () async throws -> Bool)? = nil
    ) -> (HephonAgentController, FakeWebView) {
        let controller = HephonAgentController(
            organization: "suppy-demo",
            launch: launch,
            store: "branch-7",
            locale: "ar",
            customDomains: [URL(string: "https://chat.suppy.app")!]
        )
        controller.sleep = { [unowned self] seconds in sleeps.append(seconds) }
        controller.now = { [unowned self] in clock }
        controller.onReady = { [unowned self] in log.append("ready \($0.storeId)") }
        controller.onItemAdded = { [unowned self] in log.append("added \($0.item.itemId)") }
        controller.onItemUpdated = { [unowned self] in log.append("updated \($0.item.quantity)") }
        controller.onItemRemoved = { [unowned self] in log.append("removed \($0.item.itemId)") }
        controller.onCartCleared = { [unowned self] in log.append("cleared \($0.removed.count)") }
        controller.onCheckout = { [unowned self] in log.append("checkout \($0.total)") }
        controller.onHandoff = { [unowned self] in log.append("handoff \($0.conversationId)") }
        controller.onOpenProduct = { [unowned self] in log.append("open_product \($0.itemId)") }
        controller.onClose = { [unowned self] in log.append("close") }
        controller.onSessionExpired = onSessionExpired
        controller.onMicrophonePermission = onMicrophonePermission
        let web = FakeWebView()
        controller.attach(web)
        return (controller, web)
    }

    /// What the chat page posts, from its main frame on the Hephon host.
    private func post(_ controller: HephonAgentController, _ json: String, origin: String? = hephon, main: Bool = true) {
        controller.receive(json, isMainFrame: main, origin: origin)
    }

    private func expired(_ id: String) throws -> String {
        try Fixture.page("session.expired", ["id": id])
    }

    func testLoadsTheChatOnceTheBridgeIsIn() {
        let (controller, web) = open()
        XCTAssertEqual(web.loads, [controller.url])
        XCTAssertEqual(
            controller.url.absoluteString,
            "\(hephon)/c/suppy-demo?lt=token-1&embed=ios&sdk=\(HephonCommerceSDK.version)&locale=ar"
        )
        XCTAssertEqual(controller.allowedOrigins, [hephon, "https://chat.suppy.app"])
        XCTAssertEqual(controller.pageState, .loading)
    }

    func testCallsEachTypedCallbackOncePerMessageID() throws {
        let (controller, _) = open()
        for type in [
            "ready", "cart.item_added", "cart.item_updated", "cart.item_removed", "cart.cleared",
            "checkout", "handoff", "open_product", "resize", "close",
        ] {
            try post(controller, Fixture.page(type))
        }
        // At-least-once delivery: a repeat of the same id is dropped.
        try post(controller, Fixture.page("cart.item_added"))
        // Not ours, or not this version: ignored.
        post(controller, #"{"type":"hephon-commerce:cart","cart":{}}"#)
        try post(controller, Fixture.page("cart.item_added", ["id": "other", "v": 2]))

        XCTAssertEqual(log, [
            "ready branch-7", "added 48213", "updated 3", "removed 48213", "cleared 2",
            "checkout 21.25", "handoff cm1conversation0001", "open_product 48213", "close",
        ])
        XCTAssertEqual(controller.pageState, .loaded)
    }

    func testListensOnlyToTheChatsMainFrameOnAnAllowedOrigin() throws {
        let (controller, _) = open()
        let added = try Fixture.page("cart.item_added")
        post(controller, added, main: false)
        post(controller, added, origin: "https://evil.example")
        post(controller, added, origin: "http://commerce.hephon.ai")
        post(controller, added, origin: nil)
        XCTAssertEqual(log, [])
        // The custom domain is the chat too.
        post(controller, added, origin: "https://chat.suppy.app")
        XCTAssertEqual(log, ["added 48213"])
    }

    func testForgetsTheOldestIDsPast500() throws {
        let (controller, _) = open()
        let first = try Fixture.page("cart.item_added", ["id": "id-0"])
        post(controller, first)
        for index in 1 ... HephonAgentController.seenLimit - 1 {
            try post(controller, Fixture.page("cart.item_added", ["id": "id-\(index)"]))
        }
        post(controller, first)
        XCTAssertEqual(log.count, 500)
        try post(controller, Fixture.page("cart.item_added", ["id": "id-500"]))
        post(controller, first)
        XCTAssertEqual(log.count, 502)
    }

    func testHoldsHostMessagesUntilThePageIsReady() async throws {
        let (controller, web) = open()
        controller.sendCartSnapshot([CartSnapshotItem(itemId: "48213", quantity: 2)])
        controller.focus()
        await settle()
        XCTAssertEqual(web.delivered, [])

        try post(controller, Fixture.page("ready"))
        await until { web.delivered.count == 2 }
        XCTAssertEqual(web.types, ["cart.snapshot", "focus"])
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(web.delivered[0].utf8)) as? NSDictionary
        )
        XCTAssertEqual(sent["data"] as? NSDictionary, ["items": [["itemId": "48213", "quantity": 2]]])

        controller.setTheme(.dark)
        await until { web.delivered.count == 3 }
        XCTAssertTrue(web.delivered[2].contains(#""scheme":"dark""#))

        // A reload starts a new document: hold again until it says ready.
        controller.didStartLoading()
        controller.focus()
        await settle()
        XCTAssertEqual(web.delivered.count, 3)
        try post(controller, Fixture.page("ready", ["id": "ready-2"]))
        await until { web.delivered.count == 4 }
    }

    func testDeliversOnlyWhileTheWebViewShowsTheChat() async throws {
        let (controller, web) = open()
        try post(controller, Fixture.page("ready"))
        web.url = URL(string: "https://evil.example/c/suppy-demo")
        controller.focus()
        await settle()
        XCTAssertEqual(web.delivered, [])
        web.url = URL(string: "https://chat.suppy.app/c/suppy-demo")
        controller.focus()
        await until { web.delivered.count == 1 }
    }

    func testRenewsAnExpiredSessionWithTheTokenTheAppReturns() async throws {
        let (controller, web) = open(onSessionExpired: { [unowned self] in
            asked += 1
            return "fresh-token"
        })
        try post(controller, Fixture.page("ready"))
        try post(controller, Fixture.page("session.expired"))
        await until { web.delivered.count == 1 }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(web.types, ["session.launch"])
        XCTAssertTrue(web.delivered[0].contains(#""launchToken":"fresh-token""#))
        XCTAssertEqual(sleeps, [])
    }

    func testStopsAskingForTokensThePageKeepsRefusing() async throws {
        let (controller, web) = open(onSessionExpired: { [unowned self] in
            asked += 1
            return "token-\(asked)"
        })
        // The page answers every token with another expiry, a moment later.
        var refused = 0
        web.onDeliver = { [unowned self] json in
            guard json.contains(#""type":"session.launch""#) else {
                return
            }
            refused += 1
            let id = "refused-\(refused)"
            Task { @MainActor in
                self.clock += 1
                try self.post(controller, self.expired(id))
            }
        }
        try post(controller, Fixture.page("ready"))
        try post(controller, expired("first"))
        await until { refused == 3 }
        await settle()
        XCTAssertEqual(asked, 3)
        XCTAssertEqual(web.types, ["session.launch", "session.launch", "session.launch"])
        // 2 s before the second ask, 4 s before the third.
        XCTAssertEqual(sleeps, [2, 4])
        // The shopper writes again a minute later: the controller still does not ask.
        clock += 60
        try post(controller, expired("later"))
        await settle()
        XCTAssertEqual(asked, 3)
        XCTAssertEqual(web.delivered.count, 3)
        XCTAssertEqual(sleeps, [2, 4])
    }

    func testKeepsRenewingSessionsThePageAccepted() async throws {
        let (controller, web) = open(onSessionExpired: { [unowned self] in
            asked += 1
            return "token-\(asked)"
        })
        try post(controller, Fixture.page("ready"))
        // Each renewed session lasts an hour before it expires again.
        for hour in 0 ..< 5 {
            try post(controller, expired("hour-\(hour)"))
            await until { web.delivered.count == hour + 1 }
            clock += 3600
        }
        XCTAssertEqual(asked, 5)
        XCTAssertEqual(sleeps, [])
    }

    func testAThrowingOnSessionExpiredLeavesTheChatWaiting() async throws {
        struct Offline: Error {}
        let (controller, web) = open(onSessionExpired: { [unowned self] in
            asked += 1
            throw Offline()
        })
        try post(controller, Fixture.page("ready"))
        try post(controller, expired("offline-1"))
        await until { asked == 1 }
        await settle()
        XCTAssertEqual(web.delivered, [])
        // The next expiry asks again at once: a failure is not a refused token.
        try post(controller, expired("offline-2"))
        await until { asked == 2 }
        XCTAssertEqual(sleeps, [])
    }

    func testIgnoresExpiriesWithoutARenewalCallback() async throws {
        let (controller, web) = open()
        try post(controller, Fixture.page("ready"))
        try post(controller, Fixture.page("session.expired"))
        await settle()
        XCTAssertEqual(web.delivered, [])
    }

    func testGrantsTheMicrophoneOnlyAfterTheAppHasIt() async {
        let (controller, _) = open(onMicrophonePermission: { [unowned self] in osGranted })
        var granted = await controller.allowsMicrophone(origin: hephon, microphoneOnly: true)
        XCTAssertFalse(granted)
        osGranted = true
        granted = await controller.allowsMicrophone(origin: hephon, microphoneOnly: true)
        XCTAssertTrue(granted)
        granted = await controller.allowsMicrophone(origin: "https://chat.suppy.app", microphoneOnly: true)
        XCTAssertTrue(granted)
        // Camera, or camera and microphone, or another origin: never.
        granted = await controller.allowsMicrophone(origin: hephon, microphoneOnly: false)
        XCTAssertFalse(granted)
        granted = await controller.allowsMicrophone(origin: "https://evil.example", microphoneOnly: true)
        XCTAssertFalse(granted)
        granted = await controller.allowsMicrophone(origin: nil, microphoneOnly: true)
        XCTAssertFalse(granted)
        controller.dispose()
        granted = await controller.allowsMicrophone(origin: hephon, microphoneOnly: true)
        XCTAssertFalse(granted)
    }

    func testDeniesTheMicrophoneWithoutACallbackOrWhenItThrows() async {
        struct PluginMissing: Error {}
        let (silent, _) = open()
        var granted = await silent.allowsMicrophone(origin: hephon, microphoneOnly: true)
        XCTAssertFalse(granted)
        let (throwing, _) = open(onMicrophonePermission: { throw PluginMissing() })
        granted = await throwing.allowsMicrophone(origin: hephon, microphoneOnly: true)
        XCTAssertFalse(granted)
    }

    func testKeepsTheWebViewOnTheChat() {
        let (controller, web) = open()
        func go(_ url: String, main: Bool = true) -> Bool {
            controller.navigate(to: URL(string: url)!, isMainFrame: main)
        }
        XCTAssertTrue(go("\(hephon)/c/suppy-demo?view=support"))
        XCTAssertTrue(go("https://chat.suppy.app/c/suppy-demo"))
        XCTAssertTrue(go("about:blank"))
        XCTAssertFalse(go("javascript:alert(1)", main: false))
        // A target="_blank" link: opened outside, not in the web view.
        XCTAssertFalse(go("https://evil.example/c/suppy-demo", main: false))
        // The chat's own Privacy link would replace the chat in the sheet.
        XCTAssertFalse(go("\(hephon)/legal/privacy", main: false))
        XCTAssertFalse(go("https://chat.suppy.app/legal/privacy"))
        XCTAssertFalse(go("tel:+9611234567"))
        XCTAssertEqual(web.opened.map(\.absoluteString), [
            "https://evil.example/c/suppy-demo",
            "\(hephon)/legal/privacy",
            "https://chat.suppy.app/legal/privacy",
            "tel:+9611234567",
        ])
    }

    func testReloadsTheChatNotThePageTheWebViewStrayedTo() {
        let (controller, web) = open()
        controller.didFailLoading(URLError(.notConnectedToInternet))
        XCTAssertEqual(controller.pageState, .failed)
        web.url = URL(string: "\(hephon)/c/suppy-demo?view=support")
        controller.reload()
        XCTAssertEqual(controller.pageState, .loading)
        XCTAssertEqual(web.loads.last, URL(string: "\(hephon)/c/suppy-demo?view=support"))
        web.url = URL(string: "about:blank")
        controller.reload()
        XCTAssertEqual(web.loads.last, controller.url)
        web.url = URL(string: "\(hephon)/legal/privacy")
        controller.reload()
        XCTAssertEqual(web.loads.last, controller.url)
        web.url = nil
        controller.reload()
        XCTAssertEqual(web.loads.last, controller.url)
    }

    func testReportsAFailedLoadOfTheChatNotOfOtherPages() {
        let (controller, _) = open()
        controller.didFailLoading(NSError(
            domain: "WebKitErrorDomain", code: 102,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://www.suppy.app/product/1")!]
        ))
        XCTAssertEqual(controller.pageState, .loading)
        // A load replaced by another one.
        controller.didFailLoading(URLError(.cancelled))
        XCTAssertEqual(controller.pageState, .loading)
        controller.didFailLoading(NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "\(hephon)/c/suppy-demo")!]
        ))
        XCTAssertEqual(controller.pageState, .failed)
        controller.didStartLoading()
        XCTAssertEqual(controller.pageState, .loading)
        controller.didFinishLoading()
        XCTAssertEqual(controller.pageState, .loaded)
    }

    func testUnloadsThePageWhenDisposedSoCallsAndAudioStop() async throws {
        let (controller, web) = open(onSessionExpired: { [unowned self] in
            asked += 1
            return "token"
        })
        try post(controller, Fixture.page("ready"))
        controller.dispose()
        XCTAssertTrue(web.detached)
        XCTAssertEqual(web.loads.last, URL(string: "about:blank"))
        // Disposed: nothing reaches the page or the app, a second dispose is a no-op.
        controller.focus()
        try post(controller, Fixture.page("cart.item_added"))
        try post(controller, Fixture.page("session.expired"))
        controller.didStartLoading()
        controller.reload()
        controller.dispose()
        _ = controller.navigate(to: URL(string: "https://evil.example")!, isMainFrame: false)
        await settle()
        XCTAssertEqual(web.delivered, [])
        XCTAssertEqual(log, ["ready branch-7"])
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(web.opened, [])
        XCTAssertEqual(web.loads.filter { $0.absoluteString == "about:blank" }.count, 1)
        XCTAssertEqual(controller.pageState, .loaded)
    }

    func testDisposeCancelsARenewalWaitingOnItsBackoff() async throws {
        let (controller, web) = open(onSessionExpired: { [unowned self] in
            asked += 1
            return "token-\(asked)"
        })
        var gate: CheckedContinuation<Void, Never>?
        controller.sleep = { _ in await withCheckedContinuation { gate = $0 } }
        try post(controller, Fixture.page("ready"))
        try post(controller, expired("first"))
        await until { web.delivered.count == 1 }
        try post(controller, expired("refused"))
        await until { gate != nil }
        controller.dispose()
        gate?.resume()
        await settle()
        XCTAssertEqual(asked, 1)
    }
}
