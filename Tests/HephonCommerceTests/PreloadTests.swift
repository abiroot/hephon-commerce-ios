import Foundation
@testable import HephonCommerce
import UIKit
import WebKit
import XCTest

private let hephon = "https://commerce.hephon.ai"

/// preload_v1.json: the bridge messages and URL rules added in SDK 1.1.0.
final class PreloadContractTests: XCTestCase {
    func testParsesPaintedTimingAndAReadyThatListsVisibility() throws {
        let messages = try Fixture.list("preload_v1", "pageToHost")
        let parsed = try messages.map { message in
            try XCTUnwrap(PageEvent.parse(Fixture.json(message)), "\(message["type"] ?? "?") did not parse")
        }
        XCTAssertEqual(parsed.map(\.id), messages.map { $0["id"] as? String })
        XCTAssertEqual(parsed.map(\.event), [
            .painted,
            // A preloaded first open, a reopen, a show with no frame confirmed, a page that
            // started shown.
            .timing(HephonOpenTiming(open: 85, preloaded: true)),
            .timing(HephonOpenTiming(open: 40, preloaded: true)),
            .timing(HephonOpenTiming(open: nil, preloaded: true)),
            .timing(HephonOpenTiming(open: nil, preloaded: false)),
            .message(.ready(HephonReady(
                orgSlug: "suppy-demo", storeId: "branch-7",
                capabilities: ["cart.snapshot", "session.launch", "theme", "focus", "visibility"],
                conversationId: nil, hostSessionId: nil
            ))),
        ])
    }

    /// `PageMessage` is public: a `switch` over it written for 1.0.0 has to keep compiling, so
    /// its parser gives what it gave then.
    func testThePublicParserKnowsOnlyThe100Messages() throws {
        XCTAssertNil(PageMessage.parse(try Fixture.page("painted", in: preload)))
        XCTAssertNil(PageMessage.parse(try Fixture.page("timing", in: preload)))
        let ready = try Fixture.page("ready", in: preload)
        XCTAssertEqual(PageMessage.parse(ready)?.message, PageEvent.parse(ready).flatMap {
            if case let .message(message) = $0.event { message } else { nil }
        })
        XCTAssertNotNil(PageMessage.parse(ready))
    }

    func testDropsATimingWithoutPreloadedOrWithAnOpenThatIsNotACount() throws {
        for data: [String: Any] in [
            ["open": 85],
            ["open": -1, "preloaded": true],
            ["open": 85.5, "preloaded": true],
            ["open": "85", "preloaded": true],
            ["open": 85, "preloaded": "yes"],
        ] {
            XCTAssertNil(PageEvent.parse(try Fixture.page("timing", ["data": data], in: preload)), "accepted \(data)")
        }
        XCTAssertEqual(
            PageEvent.parse(try Fixture.page("timing", ["data": ["open": 0, "preloaded": false]], in: preload))?.event,
            .timing(HephonOpenTiming(open: 0, preloaded: false))
        )
    }

    func testEncodesVisibilityAsTheFixtureDoes() throws {
        let expected = try Fixture.list("preload_v1", "hostToPage")
        XCTAssertEqual(expected.count, 3)
        for envelope in expected {
            let data = try XCTUnwrap(envelope["data"] as? [String: Any])
            let message = try HostMessage.visibility(
                XCTUnwrap(data["shown"] as? Bool),
                at: (data["at"] as? Int64).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                id: XCTUnwrap(envelope["id"] as? String),
                timestamp: Date(timeIntervalSince1970: TimeInterval(XCTUnwrap(envelope["ts"] as? Int64)) / 1000)
            )
            let encoded = try JSONSerialization.jsonObject(with: Data(message.json().utf8))
            XCTAssertEqual(encoded as? NSDictionary, envelope as NSDictionary)
        }
    }

    func testBuildsEveryRelaunchURL() throws {
        let cases = try Fixture.list("preload_v1", "relaunchUrl")
        XCTAssertEqual(cases.count, 4)
        for item in cases {
            let raw = try XCTUnwrap(item["url"] as? String)
            let url = try HephonNavigation.relaunchURL(
                XCTUnwrap(URL(string: raw)), store: XCTUnwrap(item["store"] as? String)
            )
            XCTAssertEqual(query(url), try query(XCTUnwrap(URL(string: XCTUnwrap(item["expect"] as? String)))), raw)
            XCTAssertEqual(url.path, "/c/suppy", raw)
            XCTAssertEqual(url.host, "commerce.hephon.ai", raw)
        }
    }

    func testAFreshTokenReplacesTheSpentOneAndIsEncoded() throws {
        let url = HephonNavigation.relaunchURL(
            URL(string: "\(hephon)/c/suppy?code=abc&embed=ios&sdk=1.1.0&store=s1#top")!,
            store: "s2", launchToken: "a+b/c"
        )
        XCTAssertEqual(url.absoluteString, "\(hephon)/c/suppy?lt=a%2Bb%2Fc&embed=ios&sdk=1.1.0&store=s1")
        XCTAssertEqual(
            HephonNavigation.relaunchURL(URL(string: "\(hephon)/c/suppy?lt=a.b.c")!).absoluteString,
            "\(hephon)/c/suppy"
        )
    }
}

/// The query of `url` as an unordered set of pairs, how preload_v1.json compares URLs.
private func query(_ url: URL) -> Set<String> {
    Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        .split(separator: "&").map(String.init))
}

/// The fixture of the messages added in SDK 1.1.0.
private let preload = "preload_v1"
private let blank = URL(string: "about:blank")!

/// Preload, keep-warm, release and rebuild, with the web view faked.
@MainActor
final class PreloadTests: XCTestCase {
    /// Every web view the controller made, in order.
    private var webs: [FakeWebView] = []
    private var timings: [HephonOpenTiming] = []
    private var readies = 0
    private var warnings: [String] = []
    /// Calls of the app's onSessionExpired.
    private var asked = 0
    /// Waits the controller started (seconds), each held until its gate is resumed.
    private var sleeps: [TimeInterval] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    /// Stand-ins for the views that show the chat.
    private let sheet = NSObject()
    private let secondSheet = NSObject()
    private let tap = Date(timeIntervalSince1970: 1_791_374_402.915)

    override func tearDown() async throws {
        gates.forEach { $0.resume() }
        gates = []
    }

    private func make(
        launch: HephonLaunch? = .token("token-1"),
        onSessionExpired: (@MainActor () async throws -> String?)? = nil
    ) -> HephonAgentController {
        let controller = HephonAgentController(organization: "suppy-demo", launch: launch, locale: "ar")
        controller.makeDriver = { [unowned self] _ in
            webs.append(FakeWebView())
            return webs[webs.count - 1]
        }
        controller.sleep = { [unowned self] seconds in
            sleeps.append(seconds)
            await withCheckedContinuation { gates.append($0) }
        }
        controller.warn = { [unowned self] in warnings.append($0) }
        controller.onReady = { [unowned self] _ in readies += 1 }
        controller.onTiming = { [unowned self] in timings.append($0) }
        controller.onSessionExpired = onSessionExpired
        return controller
    }

    /// The chat's token endpoint: a new token for every ask.
    private func tokens() -> @MainActor () async throws -> String? {
        { [unowned self] in
            asked += 1
            return "fresh-\(asked)"
        }
    }

    private func post(_ controller: HephonAgentController, _ json: String) {
        controller.receive(json, isMainFrame: true, origin: hephon)
    }

    /// The page in the web view says ready, listing the visibility capability unless `old`.
    private func ready(_ controller: HephonAgentController, old: Bool = false) throws {
        try post(controller, Fixture.page("ready", ["id": UUID().uuidString], in: old ? "bridge_v1" : preload))
    }

    /// The query of the chat URL once its token is spent: no token, the session's store.
    private let relaunched: Set<String> = ["embed=ios", "sdk=\(HephonCommerceSDK.version)", "locale=ar", "store=branch-7"]

    private func memoryWarning() {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    /// How often the page in `web` was unloaded.
    private func blanks(_ web: FakeWebView) -> Int {
        web.loads.filter { $0 == blank }.count
    }

    /// What each delivered `visibility` said: "shown", "shown at <ms>" or "hidden".
    private func visibility(_ web: FakeWebView) -> [String] {
        web.delivered.compactMap { json in
            guard
                let envelope = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                envelope["type"] as? String == "visibility",
                let data = envelope["data"] as? [String: Any]
            else {
                return nil
            }
            let at = (data["at"] as? Int64).map { " at \($0)" } ?? ""
            return data["shown"] as? Bool == true ? "shown\(at)" : "hidden"
        }
    }

    // MARK: - painted and timing

    func testPaintedHidesTheSpinnerAndAFinishedLoadDoesNotUndoIt() async throws {
        let controller = make()
        controller.preload()
        controller.sendCartSnapshot([])
        controller.didStartLoading()
        XCTAssertEqual(controller.pageState, .loading)
        try post(controller, Fixture.page("painted", in: preload))
        XCTAssertEqual(controller.pageState, .loaded)
        controller.didFinishLoading()
        XCTAssertEqual(controller.pageState, .loaded)
        // Painted is not ready: held messages still wait.
        await settle()
        XCTAssertEqual(webs[0].delivered, [])
        try ready(controller)
        await until { self.webs[0].delivered.count == 1 }
        // A failed chat is not painted over.
        controller.viewShown(by: sheet, at: tap)
        controller.didFailLoading(URLError(.notConnectedToInternet))
        try post(controller, Fixture.page("painted", ["id": "painted:2"], in: preload))
        XCTAssertEqual(controller.pageState, .failed)
    }

    func testCallsOnTimingOncePerTimingMessage() throws {
        let controller = make()
        controller.preload()
        let messages = try Fixture.list("preload_v1", "pageToHost").filter { $0["type"] as? String == "timing" }
        for message in messages + messages {
            post(controller, Fixture.json(message))
        }
        XCTAssertEqual(timings, [
            HephonOpenTiming(open: 85, preloaded: true),
            HephonOpenTiming(open: 40, preloaded: true),
            HephonOpenTiming(open: nil, preloaded: true),
            HephonOpenTiming(open: nil, preloaded: false),
        ])
    }

    // MARK: - visibility

    func testSaysNothingAboutVisibilityBeforeTheFirstShow() async throws {
        let controller = make()
        controller.preload()
        XCTAssertEqual(webs.count, 1)
        XCTAssertEqual(webs[0].loads, [controller.url])
        try ready(controller)
        controller.focus()
        await until { self.webs[0].delivered.count == 1 }
        XCTAssertEqual(webs[0].types, ["focus"])
    }

    func testHoldsOneVisibilityUntilReadyAndSendsItBeforeTheHeldMessages() async throws {
        let controller = make()
        controller.preload()
        // Opened, closed and opened again before the page is ready: one value is held.
        controller.viewShown(by: sheet, at: Date(timeIntervalSince1970: 1))
        controller.sendCartSnapshot([])
        controller.viewDismissed(by: sheet)
        controller.viewShown(by: sheet, at: tap)
        await settle()
        XCTAssertEqual(webs[0].delivered, [])
        try ready(controller)
        await until { self.webs[0].delivered.count == 2 }
        XCTAssertEqual(webs[0].types, ["visibility", "cart.snapshot"])
        XCTAssertEqual(visibility(webs[0]), ["shown at 1791374402915"])
    }

    func testSendsVisibilityAgainAfterEveryReadyWithAtOnlyOnAShowsFirstDelivery() async throws {
        let controller = make()
        controller.preload()
        try ready(controller)
        controller.viewShown(by: sheet, at: tap)
        await until { self.webs[0].delivered.count == 1 }
        // "Try again", or a reload after the web process ended: the new document starts hidden.
        controller.didStartLoading()
        try ready(controller)
        await until { self.webs[0].delivered.count == 2 }
        controller.viewDismissed(by: sheet)
        await until { self.webs[0].delivered.count == 3 }
        // A page loaded while hidden is told too: it would otherwise trust its own guess.
        controller.didStartLoading()
        try ready(controller)
        await until { self.webs[0].delivered.count == 4 }
        XCTAssertEqual(visibility(webs[0]), ["shown at 1791374402915", "shown", "hidden", "hidden"])
        // The view appearing again while it is shown is not a new show.
        controller.viewShown(by: sheet, at: Date())
        controller.viewShown(by: sheet, at: Date())
        await until { self.webs[0].delivered.count == 5 }
        XCTAssertEqual(visibility(webs[0]).count, 5)
    }

    // MARK: - keep, or dispose as in 1.0.0

    func testDismissingAKeptChatHidesItAndTheNextOpenUsesTheSameWebView() async throws {
        let controller = make()
        controller.preload()
        try ready(controller)
        controller.viewShown(by: sheet, at: tap)
        controller.viewDismissed(by: sheet)
        await until { self.webs[0].delivered.count == 2 }
        XCTAssertFalse(webs[0].detached)
        XCTAssertEqual(webs[0].loads, [controller.url])
        XCTAssertEqual(controller.pageState, .loaded)
        controller.viewShown(by: secondSheet, at: tap)
        await until { self.webs[0].delivered.count == 3 }
        XCTAssertEqual(webs.count, 1)
        XCTAssertEqual(visibility(webs[0]), ["shown at 1791374402915", "hidden", "shown at 1791374402915"])
    }

    func testDismissingAChatThatWasNeverPreloadedDisposesItAsIn100() async throws {
        let controller = make()
        // The view makes the web view on its way in.
        controller.viewShown(by: sheet, at: tap)
        XCTAssertEqual(webs[0].loads, [controller.url])
        try ready(controller)
        await until { self.webs[0].delivered.count == 1 }
        controller.viewDismissed(by: sheet)
        XCTAssertTrue(webs[0].detached)
        XCTAssertEqual(webs[0].loads.last, blank)
        // Disposed: nothing more happens, and preload does not bring it back.
        controller.preload()
        controller.viewShown(by: sheet, at: tap)
        await settle()
        XCTAssertEqual(webs.count, 1)
        XCTAssertEqual(visibility(webs[0]), ["shown at 1791374402915"])
        XCTAssertEqual(sleeps, [])
    }

    func testAViewDismissedLateDoesNotHideTheChatAnotherViewShows() async throws {
        let controller = make()
        controller.preload()
        try ready(controller)
        controller.viewShown(by: sheet, at: tap)
        // SwiftUI can take the old sheet apart after the new one is up.
        controller.viewShown(by: secondSheet, at: tap)
        controller.viewDismissed(by: sheet)
        await settle()
        XCTAssertEqual(visibility(webs[0]), ["shown at 1791374402915"])
        controller.viewDismissed(by: secondSheet)
        await until { self.webs[0].delivered.count == 2 }
        XCTAssertEqual(visibility(webs[0]).last, "hidden")
    }

    // MARK: - release

    func testReleasesAHiddenChatWhenIdleNeverAShownOne() async throws {
        let controller = make()
        controller.preload()
        try ready(controller)
        await until { self.gates.count == 1 }
        XCTAssertEqual(sleeps, [600])
        // Shown: the wait is over, and nothing is released when it ends.
        controller.viewShown(by: sheet, at: tap)
        gates.removeFirst().resume()
        await settle()
        XCTAssertFalse(webs[0].detached)
        // Hidden again: ten minutes from now.
        controller.viewDismissed(by: sheet)
        await until { self.gates.count == 1 }
        XCTAssertEqual(sleeps, [600, 600])
        gates.removeFirst().resume()
        await until { self.webs[0].detached }
        // Released: the page is unloaded, and the next open shows the spinner.
        XCTAssertEqual(webs[0].loads.last, blank)
        XCTAssertEqual(controller.pageState, .loading)
        XCTAssertEqual(webs.count, 1)
    }

    func testPreloadKeepsAHiddenChatForAnotherTenMinutes() async throws {
        let controller = make()
        controller.idleRelease = 5
        controller.preload()
        await until { self.gates.count == 1 }
        controller.preload()
        await until { self.gates.count == 2 }
        XCTAssertEqual(sleeps, [5, 5])
        // The first wait was replaced: its end releases nothing.
        gates.removeFirst().resume()
        await settle()
        XCTAssertFalse(webs[0].detached)
        XCTAssertEqual(webs.count, 1)
        gates.removeFirst().resume()
        await until { self.webs[0].detached }
    }

    func testReleasesOnAMemoryWarningOnlyWhileHidden() async throws {
        let controller = make()
        controller.preload()
        try ready(controller)
        controller.viewShown(by: sheet, at: tap)
        memoryWarning()
        await settle()
        XCTAssertFalse(webs[0].detached)
        controller.viewDismissed(by: sheet)
        memoryWarning()
        await until { self.webs[0].detached }
        // Cold already: a second warning does nothing, and neither does one after dispose.
        memoryWarning()
        await settle()
        XCTAssertEqual(blanks(webs[0]), 1)
        controller.preload()
        controller.dispose()
        memoryWarning()
        await settle()
        XCTAssertEqual(blanks(webs[1]), 1)
    }

    func testNeverReleasesAChatThatWasNotPreloaded() async throws {
        let controller = make()
        let web = FakeWebView()
        controller.attach(web)
        try ready(controller)
        memoryWarning()
        await settle()
        XCTAssertFalse(web.detached)
        XCTAssertEqual(sleeps, [])
    }

    func testDoesNotKeepAChatWarmWhenThePageCannotBeToldItIsHidden() async throws {
        let controller = make()
        controller.preload()
        try ready(controller, old: true)
        controller.viewShown(by: sheet, at: tap)
        await until { self.webs[0].delivered.count == 1 }
        controller.viewDismissed(by: sheet)
        // Released at once, and never told: it would not understand.
        XCTAssertTrue(webs[0].detached)
        XCTAssertEqual(webs[0].loads.last, blank)
        await settle()
        XCTAssertEqual(visibility(webs[0]), ["shown at 1791374402915"])
    }

    func testReleasesWhenAPageThatCannotBeToldSaysReadyAfterTheSheetClosed() async throws {
        let controller = make()
        controller.preload()
        controller.viewShown(by: sheet, at: tap)
        controller.viewDismissed(by: sheet)
        XCTAssertFalse(webs[0].detached)
        try ready(controller, old: true)
        XCTAssertTrue(webs[0].detached)
        XCTAssertEqual(readies, 0)
    }

    func testAWebProcessThatEndsWhileHiddenGoesColdWithoutFailing() async throws {
        let controller = make(launch: nil)
        controller.preload()
        try ready(controller)
        webs[0].url = nil
        controller.didTerminate()
        // No reload now (it would be reclaimed again) and no retry screen later.
        XCTAssertEqual(webs[0].loads, [controller.url])
        XCTAssertTrue(webs[0].detached)
        XCTAssertEqual(controller.pageState, .loading)
        controller.viewShown(by: sheet, at: tap)
        XCTAssertEqual(webs.count, 2)
        XCTAssertEqual(webs[1].loads.count, 1)
    }

    func testAWebProcessThatEndsWhileShownLoadsAgainAndTheNewPageHearsItIsShown() async throws {
        let controller = make(launch: nil)
        controller.preload()
        try ready(controller)
        controller.viewShown(by: sheet, at: tap)
        await until { self.webs[0].delivered.count == 1 }
        webs[0].url = nil
        controller.didTerminate()
        XCTAssertEqual(controller.pageState, .loading)
        XCTAssertEqual(webs.count, 1)
        // The URL is gone with the process: the chat's own, in the session's store.
        XCTAssertEqual(webs[0].loads.count, 2)
        XCTAssertEqual(query(webs[0].loads[1]), relaunched)
        controller.didStartLoading()
        try ready(controller)
        await until { self.webs[0].delivered.count == 2 }
        XCTAssertEqual(visibility(webs[0]), ["shown at 1791374402915", "shown"])
    }

    func testABlankWebViewOnShowCountsAsAnEndedProcess() async throws {
        let controller = make(launch: nil)
        controller.preload()
        try ready(controller)
        // iOS ended the process without a word.
        webs[0].url = nil
        controller.viewShown(by: sheet, at: tap)
        XCTAssertEqual(webs[0].loads.count, 2)
        XCTAssertEqual(controller.pageState, .loading)
        controller.didStartLoading()
        try ready(controller)
        await until { self.webs[0].delivered.count == 1 }
        XCTAssertEqual(visibility(webs[0]), ["shown at 1791374402915"])
    }

    func testAPreloadThatFailedOfflineIsReleasedAndLoadsAgainOnTheNextPreload() async throws {
        let controller = make(launch: nil)
        controller.preload()
        controller.didFailLoading(URLError(.notConnectedToInternet))
        XCTAssertEqual(controller.pageState, .loading)
        XCTAssertTrue(webs[0].detached)
        controller.preload()
        XCTAssertEqual(webs.count, 2)
        // Never ready, so nothing was spent: the same URL.
        XCTAssertEqual(webs[1].loads, [controller.url])
        // On screen, a failure shows the retry.
        controller.viewShown(by: sheet, at: tap)
        controller.didFailLoading(URLError(.notConnectedToInternet))
        XCTAssertEqual(controller.pageState, .failed)
        // And closing a failed chat releases it, so the next open starts clean.
        controller.viewDismissed(by: sheet)
        XCTAssertTrue(webs[1].detached)
        XCTAssertEqual(controller.pageState, .loading)
    }

    func testPreloadDoesNothingWhileTheChatIsLoadedShownOrDisposed() async throws {
        let controller = make()
        controller.preload()
        controller.preload()
        try ready(controller)
        controller.preload()
        controller.viewShown(by: sheet, at: tap)
        controller.preload()
        XCTAssertEqual(webs.count, 1)
        XCTAssertEqual(webs[0].loads, [controller.url])
        // Shown: no wait to release it is running.
        await until { self.gates.count == 3 }
        gates.forEach { $0.resume() }
        gates = []
        await settle()
        XCTAssertFalse(webs[0].detached)
        controller.dispose()
        controller.preload()
        XCTAssertEqual(webs.count, 1)
    }

    // MARK: - loading again

    func testAnIdentifiedChatLoadsAgainWithAFreshTokenAwaitedFirst() async throws {
        var answer: CheckedContinuation<String?, Never>?
        let controller = make(onSessionExpired: { [unowned self] in
            asked += 1
            return await withCheckedContinuation { answer = $0 }
        })
        controller.preload()
        try ready(controller)
        memoryWarning()
        await until { self.webs[0].detached }

        controller.viewShown(by: sheet, at: tap)
        await until { answer != nil }
        // Nothing loads until the token is here: no anonymous chat in between.
        XCTAssertEqual(webs.count, 2)
        XCTAssertEqual(webs[1].loads, [])
        XCTAssertEqual(controller.pageState, .loading)
        answer?.resume(returning: "fresh+token")
        await until { self.webs[1].loads.count == 1 }
        XCTAssertEqual(
            webs[1].loads[0].absoluteString,
            "\(hephon)/c/suppy-demo?lt=fresh%2Btoken&embed=ios&sdk=\(HephonCommerceSDK.version)&locale=ar"
        )
        try ready(controller)
        await until { self.webs[1].delivered.count == 1 }
        // The token went in the URL, not in a session.launch.
        XCTAssertEqual(webs[1].types, ["visibility"])
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(warnings, [])
    }

    func testAnIdentifiedChatWithNoHandlerLoadsTheRelaunchURLAndWarnsOnce() async throws {
        let controller = make()
        controller.preload()
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("onSessionExpired"))
        try ready(controller)
        memoryWarning()
        await until { self.webs[0].detached }
        controller.preload()
        // The spent token is gone, the session's store is kept.
        XCTAssertEqual(webs[1].loads.count, 1)
        XCTAssertEqual(query(webs[1].loads[0]), relaunched)
        try ready(controller)
        controller.focus()
        await until { self.webs[1].delivered.count == 1 }
        XCTAssertEqual(webs[1].types, ["focus"])
        XCTAssertEqual(warnings.count, 1)
    }

    func testAHandlerThatGivesNoTokenLoadsTheRelaunchURLAndWarns() async throws {
        struct Offline: Error {}
        let controller = make(onSessionExpired: { [unowned self] in
            asked += 1
            throw Offline()
        })
        controller.preload()
        XCTAssertEqual(warnings, [])
        try ready(controller)
        webs[0].url = nil
        controller.didTerminate()
        controller.preload()
        await until { self.webs[1].loads.count == 1 }
        XCTAssertEqual(query(webs[1].loads[0]), relaunched)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(warnings.count, 1)
    }

    func testAnAnonymousChatLoadsAgainInItsStoreWithoutAskingForAToken() async throws {
        let controller = make(launch: nil, onSessionExpired: tokens())
        controller.preload()
        try ready(controller)
        webs[0].url = nil
        controller.didTerminate()
        controller.preload()
        XCTAssertEqual(webs[1].loads.count, 1)
        XCTAssertEqual(query(webs[1].loads[0]), relaunched)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(warnings, [])
    }

    func testReloadNeverReplaysASpentLaunchToken() async throws {
        let controller = make(onSessionExpired: tokens())
        controller.preload()
        try ready(controller)
        // The page still has its session: no token is asked for, and none is sent.
        webs[0].url = URL(string: "\(hephon)/c/suppy-demo?lt=token-1&view=support")
        controller.reload()
        XCTAssertEqual(query(webs[0].loads[1]), ["view=support", "store=branch-7"])
        XCTAssertEqual(asked, 0)
        // The process ended on screen: the session went with it, so a fresh token first.
        controller.viewShown(by: sheet, at: tap)
        webs[0].url = nil
        controller.didTerminate()
        await until { self.webs[0].loads.count == 3 }
        XCTAssertEqual(
            webs[0].loads[2].absoluteString,
            "\(hephon)/c/suppy-demo?lt=fresh-1&embed=ios&sdk=\(HephonCommerceSDK.version)&locale=ar"
        )
    }

    func testLoadingAgainAsksAtOnceHoweverOftenAndIsNotARefusedToken() async throws {
        let controller = make(onSessionExpired: tokens())
        controller.preload()
        try ready(controller)
        for round in 1 ... 5 {
            webs[round - 1].url = nil
            controller.didTerminate()
            controller.preload()
            await until { self.webs[round].loads.count == 1 }
            try ready(controller)
        }
        XCTAssertEqual(asked, 5)
        // The waits to release a hidden chat and for each token: none between tokens.
        XCTAssertEqual(Set(sleeps), [600, 15])
        // The page then says its session ended: asked at once, as the first time.
        try post(controller, Fixture.page("session.expired"))
        await until { self.webs[5].delivered.count == 1 }
        XCTAssertEqual(webs[5].types, ["session.launch"])
        XCTAssertEqual(asked, 6)
        XCTAssertEqual(Set(sleeps), [600, 15])
    }

    func testATokenForAWebViewThatIsGoneIsNotSentToTheNextOne() async throws {
        var answers: [CheckedContinuation<String?, Never>] = []
        let controller = make(onSessionExpired: { await withCheckedContinuation { answers.append($0) } })
        controller.preload()
        try ready(controller)
        try post(controller, Fixture.page("session.expired"))
        await until { answers.count == 1 }
        // Released while the app's server is answering, then loaded again.
        memoryWarning()
        await until { self.webs[0].detached }
        controller.preload()
        XCTAssertEqual(webs[1].loads, [])
        // One request at a time: the load takes the token that was on its way.
        answers[0].resume(returning: "late")
        await until { self.webs[1].loads.count == 1 }
        XCTAssertTrue(webs[1].loads[0].absoluteString.contains("lt=late"))
        try ready(controller)
        controller.focus()
        await until { self.webs[1].delivered.count == 1 }
        XCTAssertEqual(webs[1].types, ["focus"])
        XCTAssertEqual(answers.count, 1)
    }

    func testATokenThatLoadedThePageAgainIsNotAlsoLaunchedIntoIt() async throws {
        var answers: [CheckedContinuation<String?, Never>] = []
        let controller = make(onSessionExpired: { await withCheckedContinuation { answers.append($0) } })
        controller.preload()
        try ready(controller)
        controller.viewShown(by: sheet, at: tap)
        await until { self.webs[0].delivered.count == 1 }
        try post(controller, Fixture.page("session.expired"))
        await until { answers.count == 1 }
        // The web process ends on screen while the app's server is answering: the same web
        // view loads again, with the token that was on its way.
        webs[0].url = nil
        controller.didTerminate()
        XCTAssertEqual(webs[0].loads.count, 1)
        answers[0].resume(returning: "fresh-1")
        await until { self.webs[0].loads.count == 2 }
        XCTAssertTrue(webs[0].loads[1].absoluteString.contains("lt=fresh-1"))
        controller.didStartLoading()
        try ready(controller)
        await until { self.webs[0].delivered.count == 2 }
        await settle()
        // A token works once: it is not sent to the new page a second time.
        XCTAssertEqual(webs[0].types, ["visibility", "visibility"])
        XCTAssertEqual(answers.count, 1)
        // And the new page did not refuse it: its first expiry is asked at once.
        try post(controller, Fixture.page("session.expired", ["id": "expired:2"]))
        await until { answers.count == 2 }
        XCTAssertFalse(sleeps.contains(2))
        answers[1].resume(returning: nil)
    }

    func testALoadStopsWaitingForATokenAfter15Seconds() async throws {
        var answers: [CheckedContinuation<String?, Never>] = []
        let controller = make(onSessionExpired: { await withCheckedContinuation { answers.append($0) } })
        controller.preload()
        try ready(controller)
        controller.viewShown(by: sheet, at: tap)
        await until { self.webs[0].delivered.count == 1 }
        webs[0].url = nil
        controller.didTerminate()
        await until { self.sleeps.last == 15 && self.gates.count == self.sleeps.count }
        XCTAssertEqual(webs[0].loads.count, 1)
        XCTAssertEqual(controller.pageState, .loading)
        XCTAssertEqual(warnings, [])
        // The app's server never answered: the chat loads without the shopper, not never.
        gates.removeLast().resume()
        await until { self.webs[0].loads.count == 2 }
        XCTAssertEqual(query(webs[0].loads[1]), relaunched)
        XCTAssertEqual(warnings.count, 1)
        // An answer after that is for nobody.
        controller.didStartLoading()
        try ready(controller)
        answers[0].resume(returning: "late")
        await until { self.webs[0].delivered.count == 2 }
        await settle()
        XCTAssertEqual(webs[0].loads.count, 2)
        XCTAssertEqual(webs[0].types, ["visibility", "visibility"])
    }

    func testARebuildReleasedAgainWhileItWaitsForItsTokenDoesNotLoad() async throws {
        var answer: CheckedContinuation<String?, Never>?
        let controller = make(onSessionExpired: { await withCheckedContinuation { answer = $0 } })
        controller.preload()
        try ready(controller)
        webs[0].url = nil
        controller.didTerminate()
        controller.preload()
        await until { answer != nil }
        memoryWarning()
        await until { self.webs[1].detached }
        answer?.resume(returning: "late")
        await settle()
        XCTAssertEqual(webs[1].loads, [blank])
    }

    func testHoldsMessagesWhileReleasedAndDeliversThemAfterTheNextReady() async throws {
        let controller = make(launch: nil)
        controller.preload()
        try ready(controller)
        webs[0].url = nil
        controller.didTerminate()
        controller.sendCartSnapshot([CartSnapshotItem(itemId: "48213", quantity: 2)])
        await settle()
        controller.viewShown(by: sheet, at: tap)
        try ready(controller)
        await until { self.webs[1].delivered.count == 2 }
        XCTAssertEqual(webs[0].delivered, [])
        XCTAssertEqual(webs[1].types, ["visibility", "cart.snapshot"])
        XCTAssertEqual(readies, 2)
    }

    func testDisposeEndsAKeptChatForGood() async throws {
        let controller = make()
        controller.preload()
        try ready(controller)
        controller.dispose()
        XCTAssertTrue(webs[0].detached)
        XCTAssertEqual(webs[0].loads.last, blank)
        // The wait to release it is over too.
        await until { self.gates.count == 1 }
        gates.removeFirst().resume()
        controller.viewShown(by: sheet, at: tap)
        controller.viewDismissed(by: sheet)
        await settle()
        XCTAssertEqual(webs.count, 1)
        XCTAssertEqual(blanks(webs[0]), 1)
        XCTAssertEqual(webs[0].delivered, [])
    }
}

/// A real WKWebView and view controller: the chat loads outside any view, moves into the view
/// that shows it, and leaves it again when that view goes.
@MainActor
final class PreloadWebKitTests: XCTestCase {
    func testLoadsOutsideAnyViewThenMovesIntoTheViewThatShowsIt() async throws {
        var events: [String] = []
        let controller = HephonAgentController(organization: "suppy-demo")
        controller.onTiming = { events.append("timing \($0.preloaded)") }
        controller.preload()
        let webView = controller.webView()
        // What a show reads to tell a loaded chat from one whose process ended.
        XCTAssertEqual(webView.url, controller.url)
        XCTAssertNil(webView.superview)

        // The chat page, stood in by one that says painted and ready, and answers the
        // visibility it is told with a timing.
        let ready = try Fixture.page("ready", in: preload)
        let painted = try Fixture.page("painted", in: preload)
        webView.loadHTMLString(
            """
            <script>
            const post = (m) => window.webkit.messageHandlers.HephonBridge.postMessage(JSON.stringify(m));
            window.hephon = { receive(json) {
                const m = JSON.parse(json);
                if (m.type === "visibility" && m.data.shown && m.data.at)
                    post({ v: 1, id: "t-" + m.id, type: "timing", ts: Date.now(),
                           data: { open: Date.now() - m.data.at, preloaded: true } });
            } };
            window.webkit.messageHandlers.HephonBridge.postMessage(\(Fixture.json(painted)));
            window.webkit.messageHandlers.HephonBridge.postMessage(\(Fixture.json(ready)));
            </script>
            """,
            baseURL: controller.url
        )
        // WebKit's first launch on a simulator that has just booted can take a minute.
        await untilWebKit(seconds: 120) { controller.pageState == .loaded }
        XCTAssertEqual(events, [])

        let sheet = HephonAgentViewController(controller: controller)
        sheet.loadViewIfNeeded()
        sheet.beginAppearanceTransition(true, animated: false)
        sheet.endAppearanceTransition()
        XCTAssertIdentical(webView.superview, sheet.view)
        XCTAssertIdentical(sheet.view.subviews.first, webView)
        await untilWebKit { events.count == 1 }
        XCTAssertEqual(events, ["timing true"])

        // SwiftUI takes the view apart: the chat stays loaded, in the same web view.
        HephonAgentView.dismantleUIViewController(sheet, coordinator: ())
        XCTAssertNil(webView.superview)
        XCTAssertIdentical(controller.webView(), webView)
        XCTAssertEqual(controller.pageState, .loaded)

        let again = HephonAgentViewController(controller: controller)
        again.loadViewIfNeeded()
        again.beginAppearanceTransition(true, animated: false)
        again.endAppearanceTransition()
        XCTAssertIdentical(webView.superview, again.view)
        await untilWebKit { events.count == 2 }
        controller.dispose()
    }

    /// The view inside a container of the app's own. UIKit says a view is being dismissed only
    /// during a real dismissal, which needs an app; the container says it here.
    private final class Container: UIViewController {
        var going = false
        override var isBeingDismissed: Bool {
            going
        }
    }

    /// A chat in a container, on screen, and how many times it began the wait to be released.
    private func contained(preloaded: Bool) -> (Container, HephonAgentViewController, WKWebView, () -> Int) {
        var waits = 0
        let controller = HephonAgentController(organization: "suppy-demo")
        controller.sleep = { _ in
            waits += 1
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if preloaded {
            controller.preload()
        }
        let webView = controller.webView()
        // Nothing from the network.
        webView.loadHTMLString("", baseURL: controller.url)
        let container = Container()
        let sheet = HephonAgentViewController(controller: controller)
        container.addChild(sheet)
        container.view.addSubview(sheet.view)
        sheet.didMove(toParent: container)
        sheet.beginAppearanceTransition(true, animated: false)
        sheet.endAppearanceTransition()
        XCTAssertIdentical(webView.superview, sheet.view)
        return (container, sheet, webView, { waits })
    }

    private func disappear(_ sheet: UIViewController) {
        sheet.beginAppearanceTransition(false, animated: false)
        sheet.endAppearanceTransition()
    }

    func testAKeptChatIsHiddenWhenAContainerItIsInIsDismissed() async throws {
        let (container, sheet, webView, waits) = contained(preloaded: true)
        await settle()
        XCTAssertEqual(waits(), 1)
        // Covered (another tab, a screen pushed over the container): still shown.
        disappear(sheet)
        await settle()
        XCTAssertIdentical(webView.superview, sheet.view)
        XCTAssertEqual(waits(), 1)
        sheet.beginAppearanceTransition(true, animated: false)
        sheet.endAppearanceTransition()
        // The container is dismissed: the chat is hidden, out of the view, and waits to be released.
        container.going = true
        disappear(sheet)
        await settle()
        XCTAssertNil(webView.superview)
        XCTAssertEqual(waits(), 2)
        XCTAssertIdentical(sheet.controller.webView(), webView)
        sheet.controller.dispose()
    }

    func testAChatThatWasNeverPreloadedStaysAsIn100WhenItsContainerIsDismissed() async throws {
        let (container, sheet, webView, _) = contained(preloaded: false)
        container.going = true
        disappear(sheet)
        XCTAssertIdentical(webView.superview, sheet.view)
        // Not disposed: it can still be loaded again.
        sheet.controller.didFailLoading(URLError(.notConnectedToInternet))
        XCTAssertEqual(sheet.controller.pageState, .failed)
        sheet.controller.dispose()
    }
}
