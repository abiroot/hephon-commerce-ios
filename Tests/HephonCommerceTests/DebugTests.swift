import Foundation
@testable import HephonCommerce
import XCTest

private let hephon = "https://commerce.hephon.ai"

/// debug_v1.json: debug mode, since SDK 2.3.0.
final class DebugContractTests: XCTestCase {
    func testParsesEveryLogAndRejectsTheBadOnes() throws {
        for message in try Fixture.list("debug_v1", "pageToHost") {
            let data = try XCTUnwrap(message["data"] as? [String: Any])
            let parsed = try XCTUnwrap(PageEvent.parse(Fixture.json(message)), "\(message["id"] ?? "?") did not parse")
            XCTAssertEqual(parsed.id, message["id"] as? String)
            XCTAssertEqual(
                parsed.event,
                try .log(level: XCTUnwrap(data["level"] as? String), message: XCTUnwrap(data["message"] as? String))
            )
            // `log` is not a case of the 1.0.0 PageMessage, so a switch over it still compiles.
            XCTAssertNil(PageMessage.parse(Fixture.json(message)))
        }
        for message in try Fixture.list("debug_v1", "rejected") {
            XCTAssertNil(PageEvent.parse(Fixture.json(message)), "accepted \(message["$comment"] ?? "?")")
        }
    }

    func testAddsTheDebugParameterToTheChatURL() throws {
        let param = try XCTUnwrap(Fixture.object("debug_v1")["chatUrl"] as? [String: String])
        let url = HephonAgentController.chatURL(
            host: URL(string: hephon)!, organization: "suppy-demo", locale: "ar",
            appearance: HephonAppearance(scheme: .dark), debug: true
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(URLQueryItem(name: param["param"]!, value: param["value"])))
        // After the locale, before the appearance overrides.
        XCTAssertEqual(items.map(\.name), ["embed", "sdk", "locale", "debug", "scheme"])
    }
}

@MainActor
final class DebugTests: XCTestCase {
    private var lines: [String] = []
    private var webs: [FakeWebView] = []

    private func make(
        launch: HephonLaunch? = .token("token-1"), debug: Bool = true, checkout: Bool = true
    ) -> HephonAgentController {
        let controller = HephonAgentController(
            organization: "suppy-demo", launch: launch, store: "branch-7", debug: debug,
            onLog: { [unowned self] in lines.append($0) }
        )
        if checkout {
            controller.onCheckout = { _ in }
        }
        controller.onSessionExpired = { nil }
        controller.sleep = { _ in }
        controller.makeDriver = { [unowned self] _ in
            let web = FakeWebView()
            webs.append(web)
            return web
        }
        return controller
    }

    private func post(_ controller: HephonAgentController, _ json: String) {
        controller.receive(json, isMainFrame: true, origin: hephon)
    }

    func testIsOffByDefaultNoParameterAndNothingLogged() throws {
        let controller = make(debug: false)
        controller.preload()
        controller.openBasket()
        try post(controller, Fixture.page("ready"))
        try post(controller, Fixture.page("checkout"))
        XCTAssertNil(URLComponents(url: controller.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "debug" })
        XCTAssertFalse(controller.debug)
        XCTAssertEqual(lines, [])
    }

    func testTracesTheLoadBothWaysOfTheBridgeAndOnCheckoutWithoutTheToken() async throws {
        let controller = make()
        XCTAssertTrue(controller.isInspectable)
        controller.preload()
        controller.openBasket()
        try post(controller, Fixture.page("ready"))
        try post(controller, Fixture.json(XCTUnwrap(Fixture.list("debug_v1", "pageToHost").first)))
        try post(controller, Fixture.page("checkout"))
        try post(controller, Fixture.page("checkout"))
        await settle()

        XCTAssertTrue(
            try XCTUnwrap(lines.first).hasPrefix("load \(hephon)/c/suppy-demo?lt=%E2%80%A6&"),
            "\(lines)"
        )
        XCTAssertFalse(lines.joined(separator: "\n").contains("token-1"))
        XCTAssertInOrder(lines.filter { !$0.hasPrefix("load ") }, [
            #"^-> basket\.open \S+ held until the chat is ready$"#,
            #"^<- ready "#,
            #"^-> basket\.open "#,
            #"^page info: press \(touch\) button "Check out" at 186,812$"#,
            #"^<- checkout "#,
            #"^onCheckout: \d+ items, total 21\.25 "#,
            #"^<- checkout \S+ again: ignored$"#,
        ])
        // A page's log is printed as its line, not as a message received.
        XCTAssertFalse(lines.contains { $0.hasPrefix("<- log ") })
    }

    func testSaysSoWhenThePageChecksOutAndNoOnCheckoutIsSet() throws {
        let controller = make(launch: nil, checkout: false)
        controller.preload()
        try post(controller, Fixture.page("checkout"))
        XCTAssertTrue(try XCTUnwrap(lines.last).hasSuffix("items, but no onCheckout is set"), "\(lines)")
    }

    func testTracesShownHiddenReleasedPagesAndLoadErrors() async throws {
        let controller = make(launch: .code("code-1"))
        let sheet = NSObject()
        let page = "\(hephon)/c/suppy-demo?code=%E2%80%A6&embed=ios&sdk=\(HephonCommerceSDK.version)&debug=1"
        let close = try Fixture.page("close")
        let closeId = try XCTUnwrap(PageEvent.parse(close)).id
        controller.preload()
        controller.didStartLoading()
        controller.didFinishLoading()
        controller.viewShown(by: sheet, at: Date())
        post(controller, close)
        controller.viewDismissed(by: sheet)
        await settle()
        controller.didFailLoading(URLError(
            .notConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: controller.url]
        ))
        XCTAssertEqual(Array(lines.dropLast()), [
            "load \(page)",
            "page started \(page)",
            "page finished \(page)",
            "shown",
            "<- close \(closeId)",
            "close, but nothing to close",
            "hidden",
            "released: the next show or preload() loads the chat again",
        ])
        let error = try XCTUnwrap(lines.last)
        XCTAssertTrue(error.hasPrefix("load error -1009 NSURLErrorDomain "), error)
        XCTAssertTrue(error.hasSuffix(" (main frame: true, \(page))"), error)
        XCTAssertFalse(lines.joined().contains("code-1"))
    }
}

/// Each of `patterns` matches a line of `lines`, in order (other lines may come between).
func XCTAssertInOrder(
    _ lines: [String], _ patterns: [String], file: StaticString = #filePath, line: UInt = #line
) {
    var rest = lines[...]
    for pattern in patterns {
        guard let at = rest.firstIndex(where: { $0.range(of: pattern, options: .regularExpression) != nil }) else {
            return XCTFail("no line matches \(pattern) in order: \(lines)", file: file, line: line)
        }
        rest = rest[(at + 1)...]
    }
}
