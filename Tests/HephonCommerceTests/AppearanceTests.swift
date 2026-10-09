import Foundation
@testable import HephonCommerce
import XCTest

private let hephon = "https://commerce.hephon.ai"

/// The `appearance` object of a fixture case as the app would write it.
private func appearance(_ data: [String: Any]) throws -> HephonAppearance {
    try HephonAppearance(
        scheme: (data["scheme"] as? String).map { try XCTUnwrap(HephonAppearance.Scheme(rawValue: $0), $0) },
        primaryColor: data["primaryColor"] as? String,
        deepColor: data["deepColor"] as? String,
        accentColor: data["accentColor"] as? String,
        dealColor: data["dealColor"] as? String,
        corners: (data["corners"] as? String).map { try XCTUnwrap(HephonAppearance.Corners(rawValue: $0), $0) },
        header: (data["header"] as? String).map { try XCTUnwrap(HephonAppearance.Header(rawValue: $0), $0) },
        ctaColor: data["ctaColor"] as? String,
        headerColor: data["headerColor"] as? String,
        bubbleColor: data["bubbleColor"] as? String,
        surfaceColor: data["surfaceColor"] as? String,
        buttons: (data["buttons"] as? String).map { try XCTUnwrap(HephonAppearance.Buttons(rawValue: $0), $0) },
        bubble: (data["bubble"] as? String).map { try XCTUnwrap(HephonAppearance.Bubble(rawValue: $0), $0) },
        font: (data["font"] as? String).map { try XCTUnwrap(HephonAppearance.Font(rawValue: $0), $0) },
        starterStyle: (data["starterStyle"] as? String).map {
            try XCTUnwrap(HephonAppearance.StarterStyle(rawValue: $0), $0)
        },
        showHeader: data["showHeader"] as? Bool,
        showLogo: data["showLogo"] as? Bool,
        showBasket: data["showBasket"] as? Bool,
        showCheckout: data["showCheckout"] as? Bool,
        showNewChat: data["showNewChat"] as? Bool,
        showFollowUps: data["showFollowUps"] as? Bool,
        showSteps: data["showSteps"] as? Bool,
        productSheet: data["productSheet"] as? Bool,
        addFromCards: data["addFromCards"] as? Bool
    )
}

/// The data of a fixture `text` message as the app would write it.
private func text(_ data: [String: Any]) -> HephonText {
    let labels = data["labels"] as? [String: String]
    return HephonText(
        welcomeTitle: data["welcomeTitle"] as? String,
        welcomeSubtitle: data["welcomeSubtitle"] as? String,
        placeholder: data["placeholder"] as? String,
        tagline: data["tagline"] as? String,
        labels: labels.map {
            HephonText.Labels(
                viewBasket: $0["viewBasket"], basketTitle: $0["basketTitle"], checkout: $0["checkout"],
                addToBasket: $0["addToBasket"], orderHelp: $0["orderHelp"], newChat: $0["newChat"]
            )
        }
    )
}

/// Every override set, each to a value of its own.
private let everything = HephonAppearance(
    scheme: .auto, primaryColor: "#000001", deepColor: "#000002", accentColor: "#000003",
    dealColor: "#000004", corners: .square, header: .plain,
    ctaColor: "#000005", headerColor: "#000006", bubbleColor: "#000007", surfaceColor: "#000008",
    buttons: .pill, bubble: .soft, font: .manrope, starterStyle: .photos,
    showHeader: true, showLogo: false, showBasket: true, showCheckout: false, showNewChat: true,
    showFollowUps: false, showSteps: true, productSheet: false, addFromCards: true
)

/// appearance_v1.json: what an app may restyle in the chat it opens, since SDK 1.2.0.
final class AppearanceContractTests: XCTestCase {
    func testCoversExactlyTheFixturesKeysAndValues() throws {
        let fixture = try Fixture.object("appearance_v1")
        XCTAssertEqual(HephonAppearance.keys, fixture["keys"] as? [String])
        let values = try XCTUnwrap(fixture["values"] as? [String: [String]])
        XCTAssertEqual(values.count, 7)
        XCTAssertEqual(HephonAppearance.Buttons.allCases.map(\.rawValue), values["buttons"])
        XCTAssertEqual(HephonAppearance.Bubble.allCases.map(\.rawValue), values["bubble"])
        XCTAssertEqual(HephonAppearance.Font.allCases.map(\.rawValue), values["font"])
        XCTAssertEqual(HephonAppearance.StarterStyle.allCases.map(\.rawValue), values["starterStyle"])
        XCTAssertEqual(HephonAppearance.Scheme.allCases.map(\.rawValue), values["scheme"])
        XCTAssertEqual(HephonAppearance.Corners.allCases.map(\.rawValue), values["corners"])
        XCTAssertEqual(HephonAppearance.Header.allCases.map(\.rawValue), values["header"])

        // Every key is a field: all set, all sent, in the fixture's order.
        let pairs = everything.pairs
        XCTAssertEqual(pairs.count, 24)
        XCTAssertEqual(pairs.map(\.0), HephonAppearance.keys)
        XCTAssertEqual(pairs.map(\.1.query), [
            "auto", "#000001", "#000002", "#000003", "#000004", "square", "plain",
            "#000005", "#000006", "#000007", "#000008", "pill", "soft", "manrope", "photos",
            "true", "false", "true", "false", "true", "false", "true", "false", "true",
        ])
        // The colours are the fields that take #RRGGBB, the flags the ones sent as booleans.
        XCTAssertEqual(pairs.filter { $0.1.query.hasPrefix("#") }.map(\.0), fixture["colors"] as? [String])
        XCTAssertEqual(
            pairs.filter { if case .flag = $0.1 { true } else { false } }.map(\.0),
            fixture["flags"] as? [String]
        )
        XCTAssertTrue(HephonAppearance().pairs.isEmpty)
    }

    func testTextCoversExactlyTheFixturesKeysAndLabels() throws {
        let fixture = try Fixture.object("appearance_v1")
        XCTAssertEqual(HephonText.keys, fixture["textKeys"] as? [String])
        XCTAssertEqual(HephonText.Labels.keys, fixture["labels"] as? [String])
        let labels = HephonText.Labels(
            viewBasket: "1", basketTitle: "2", checkout: "3", addToBasket: "4", orderHelp: "5", newChat: "6"
        )
        XCTAssertEqual(labels.pairs.map(\.0), HephonText.Labels.keys)
        XCTAssertEqual(labels.pairs.map(\.1), ["1", "2", "3", "4", "5", "6"])
        let all = HephonText(welcomeTitle: "a", welcomeSubtitle: "b", placeholder: "c", tagline: "d", labels: labels)
        XCTAssertEqual(all.pairs.map(\.0) + ["labels"], HephonText.keys)
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(HostMessage.text(all).json().utf8)) as? [String: Any]
        )
        let data = try XCTUnwrap(sent["data"] as? [String: Any])
        XCTAssertEqual(Set(data.keys), Set(HephonText.keys))
        XCTAssertEqual(Set(try XCTUnwrap(data["labels"] as? [String: String]).keys), Set(HephonText.Labels.keys))
    }

    /// A flag that is set is sent whether it is true or false; text is never on the URL.
    func testWritesAFlagThatIsFalseOnTheURL() {
        let url = HephonAgentController.chatURL(
            host: HephonAgentController.defaultHost, organization: "suppy",
            appearance: HephonAppearance(surfaceColor: "#F8FAFC", showBasket: false, addFromCards: true)
        )
        XCTAssertEqual(
            url.absoluteString,
            "\(hephon)/c/suppy?embed=ios&sdk=\(HephonCommerceSDK.version)&surfaceColor=%23F8FAFC&showBasket=false&addFromCards=true"
        )
    }

    func testMergesWhatWasSetOverWhatWasSetBefore() {
        let first = HephonAppearance(scheme: .dark, primaryColor: "#000001", showBasket: false, showSteps: true)
        let merged = first.merging(HephonAppearance(primaryColor: "#000002", font: .system, showBasket: true))
        XCTAssertEqual(
            merged,
            HephonAppearance(scheme: .dark, primaryColor: "#000002", font: .system, showBasket: true, showSteps: true)
        )
        XCTAssertEqual(everything.merging(HephonAppearance()), everything)
        XCTAssertEqual(HephonAppearance().merging(everything), everything)

        let text = HephonText(welcomeTitle: "Hi", tagline: "Fast", labels: .init(checkout: "Pay", newChat: "New"))
        XCTAssertEqual(
            text.merging(HephonText(tagline: "Faster", labels: .init(viewBasket: "Cart", checkout: "Pay now"))),
            HephonText(
                welcomeTitle: "Hi", tagline: "Faster",
                labels: .init(viewBasket: "Cart", checkout: "Pay now", newChat: "New")
            )
        )
        // No labels in the later one: the earlier ones stay.
        XCTAssertEqual(text.merging(HephonText(placeholder: "Ask")).labels, text.labels)
        XCTAssertEqual(HephonText().merging(text), text)
    }

    func testBuildsEveryChatURL() throws {
        let cases = try Fixture.list("appearance_v1", "chatUrl")
        XCTAssertEqual(cases.count, 5)
        for item in cases {
            let comment = item["$comment"] as? String ?? ""
            let url = try HephonAgentController.chatURL(
                host: XCTUnwrap(URL(string: XCTUnwrap(item["host"] as? String))),
                organization: XCTUnwrap(item["organization"] as? String),
                launch: (item["launchToken"] as? String).map(HephonLaunch.token),
                store: item["store"] as? String,
                locale: item["locale"] as? String,
                appearance: appearance(XCTUnwrap(item["appearance"] as? [String: Any])),
                embed: XCTUnwrap(item["embed"] as? String),
                sdk: XCTUnwrap(item["sdk"] as? String)
            )
            let expected = try XCTUnwrap(URL(string: XCTUnwrap(item["expect"] as? String)))
            XCTAssertEqual(Parts(url), Parts(expected), comment)
            // A bare # would start the fragment and the colour would never reach the page.
            XCTAssertNil(url.fragment, comment)
            XCTAssertFalse(url.absoluteString.contains("#"), comment)
        }
    }

    func testTheChatURLKeepsTheFixturesOrderAndEncodesTheHash() {
        let url = HephonAgentController.chatURL(
            host: HephonAgentController.defaultHost,
            organization: "suppy-demo",
            launch: .token("token-1"),
            locale: "ar",
            appearance: HephonAppearance(
                scheme: .auto, primaryColor: "#1E1EF2", deepColor: "#0B0B6B", accentColor: "#D9F99D",
                dealColor: "#15803D", corners: .soft, header: .brand
            ),
            embed: "flutter",
            sdk: "1.2.0"
        )
        XCTAssertEqual(
            url.absoluteString,
            "\(hephon)/c/suppy-demo?lt=token-1&embed=flutter&sdk=1.2.0&locale=ar&scheme=auto&primaryColor=%231E1EF2&deepColor=%230B0B6B&accentColor=%23D9F99D&dealColor=%2315803D&corners=soft&header=brand"
        )
        // No appearance, or one with nothing set: the URL host_v1.json describes.
        let plain = HephonAgentController.chatURL(host: HephonAgentController.defaultHost, organization: "suppy")
        XCTAssertEqual(
            HephonAgentController.chatURL(
                host: HephonAgentController.defaultHost, organization: "suppy", appearance: HephonAppearance()
            ),
            plain
        )
        XCTAssertEqual(plain.absoluteString, "\(hephon)/c/suppy?embed=ios&sdk=\(HephonCommerceSDK.version)")
    }

    func testEncodesAppearanceAsTheFixtureDoes() throws {
        let expected = try Fixture.list("appearance_v1", "hostToPage")
        XCTAssertEqual(expected.map { $0["type"] as? String }, [
            "appearance", "appearance", "appearance", "appearance", "text", "text", "text",
        ])
        for envelope in expected {
            let data = try XCTUnwrap(envelope["data"] as? [String: Any])
            let id = try XCTUnwrap(envelope["id"] as? String)
            let at = try Date(timeIntervalSince1970: TimeInterval(XCTUnwrap(envelope["ts"] as? Int64)) / 1000)
            let message: HostMessage = envelope["type"] as? String == "text"
                ? .text(text(data), id: id, timestamp: at)
                : try .appearance(appearance(data), id: id, timestamp: at)
            XCTAssertEqual(message.type, envelope["type"] as? String)
            let encoded = try JSONSerialization.jsonObject(with: Data(message.json().utf8))
            XCTAssertEqual(encoded as? NSDictionary, envelope as NSDictionary)
        }
    }

    func testParsesAReadyThatListsAppearance() throws {
        let ready = try XCTUnwrap(Fixture.object("appearance_v1")["ready"] as? [String: Any])
        guard case let .ready(parsed) = PageMessage.parse(Fixture.json(ready))?.message else {
            return XCTFail("the ready message did not parse")
        }
        XCTAssertEqual(
            parsed.capabilities,
            ["cart.snapshot", "session.launch", "theme", "focus", "visibility", "appearance", "text"]
        )
        XCTAssertEqual(parsed.storeId, "branch-7")
    }

    func testAColourIsAHashAndSixHexDigits() {
        for good in ["#1E1EF2", "#e11d48", "#000000", "#FFFFFF", "#aBcDeF"] {
            XCTAssertTrue(HephonAppearance.isColor(good), good)
        }
        for bad in [
            "", "#", "1E1EF2", "#1E1EF", "#1E1EF2F", "#1E1EFG", "#FFF", "#1E1EF2FF", " #1E1EF2", "#1E1EF2 ",
            "#1E1EF2\n", "red", "rgb(0,0,0)", "%231E1EF2", "##1E1EF", "#١٢٣٤٥٦",
        ] {
            XCTAssertFalse(HephonAppearance.isColor(bad), "accepted \(bad.debugDescription)")
        }
    }

    /// What `HephonAppearance.init` stores: a bad colour is dropped (after an assertion that
    /// only a debug build has), a good one is kept as written.
    func testDropsAColourThatIsNotOne() {
        XCTAssertEqual(HephonAppearance.color("#e11d48"), "#e11d48")
        XCTAssertEqual(HephonAppearance.color("#1E1EF2"), "#1E1EF2")
        XCTAssertNil(HephonAppearance.color(nil))
        for bad in ["", "red", "#FFF", "1E1EF2", "#1E1EFG", "#1E1EF2FF"] {
            XCTAssertNil(HephonAppearance.color(bad), "kept \(bad.debugDescription)")
        }
        // All eight colours go through it.
        let kept = HephonAppearance(
            primaryColor: "#e11d48", deepColor: "#000002", accentColor: "#000003", dealColor: "#15803D",
            ctaColor: "#0A7A3D", headerColor: "#111827", bubbleColor: "#2563EB", surfaceColor: "#F8FAFC"
        )
        XCTAssertEqual(
            kept.pairs.map(\.1.query),
            ["#e11d48", "#000002", "#000003", "#15803D", "#0A7A3D", "#111827", "#2563EB", "#F8FAFC"]
        )
        XCTAssertNil(HephonAppearance(primaryColor: "#e11d48").deepColor)
    }

    /// `theme` is as it was in 1.0.0: light or dark, nothing else.
    func testThemeStillSendsOnlyItsScheme() throws {
        for (scheme, name) in [(HephonScheme.light, "light"), (.dark, "dark")] {
            let sent = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(HostMessage.theme(scheme).json().utf8)) as? NSDictionary
            )
            XCTAssertEqual(sent["type"] as? String, "theme")
            XCTAssertEqual(sent["data"] as? NSDictionary, ["scheme": name])
        }
    }
}

@MainActor
final class AppearanceControllerTests: XCTestCase {
    private let look = HephonAppearance(scheme: .dark, primaryColor: "#1E1EF2", corners: .soft, header: .brand)
    private let params = "scheme=dark&primaryColor=%231E1EF2&corners=soft&header=brand"
    private var asked = 0

    private func open(launch: HephonLaunch?) -> (HephonAgentController, FakeWebView) {
        let controller = HephonAgentController(
            organization: "suppy-demo", launch: launch, store: "branch-7", locale: "ar", appearance: look
        )
        controller.sleep = { _ in }
        let web = FakeWebView()
        controller.attach(web)
        return (controller, web)
    }

    private func data(_ json: String, _ type: String = "appearance") throws -> NSDictionary {
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        XCTAssertEqual(sent["type"] as? String, type)
        return try XCTUnwrap(sent["data"] as? NSDictionary)
    }

    func testOpensTheChatWithItsOverrides() {
        let (controller, web) = open(launch: .token("token-1"))
        XCTAssertEqual(
            controller.url.absoluteString,
            "\(hephon)/c/suppy-demo?lt=token-1&embed=ios&sdk=\(HephonCommerceSDK.version)&locale=ar&\(params)"
        )
        XCTAssertEqual(web.loads, [controller.url])
    }

    func testHoldsSetAppearanceUntilThePageIsReady() async throws {
        let (controller, web) = open(launch: .token("token-1"))
        controller.setAppearance(HephonAppearance(scheme: .light))
        controller.setAppearance(HephonAppearance(primaryColor: "#e11d48", header: .plain))
        controller.setAppearance(HephonAppearance())
        await settle()
        XCTAssertEqual(web.delivered, [])

        try post(controller, Fixture.page("ready"))
        await until { web.delivered.count == 3 }
        XCTAssertEqual(web.types, ["appearance", "appearance", "appearance"])
        // Only the fields that were set, each message by itself: the page does the merging.
        XCTAssertEqual(try data(web.delivered[0]), ["scheme": "light"])
        XCTAssertEqual(try data(web.delivered[1]), ["primaryColor": "#e11d48", "header": "plain"])
        XCTAssertEqual(try data(web.delivered[2]), [:])

        // Ready: sent at once. A new document: held again.
        controller.setAppearance(HephonAppearance(corners: .square))
        await until { web.delivered.count == 4 }
        XCTAssertEqual(try data(web.delivered[3]), ["corners": "square"])
        controller.didStartLoading()
        controller.setAppearance(HephonAppearance(scheme: .auto, showBasket: false))
        await settle()
        XCTAssertEqual(web.delivered.count, 4)
        try post(controller, Fixture.page("ready", ["id": "ready-2"]))
        // The new page has only the chat URL's overrides: everything set since, merged, then
        // what was held.
        await until { web.delivered.count == 6 }
        XCTAssertEqual(try data(web.delivered[4]), [
            "scheme": "auto", "primaryColor": "#e11d48", "header": "plain", "corners": "square",
            "showBasket": false,
        ])
        XCTAssertEqual(try data(web.delivered[5]), ["scheme": "auto", "showBasket": false])
        // A JSON boolean, not the word.
        XCTAssertTrue(web.delivered[5].contains(#""showBasket":false"#))
    }

    func testHoldsTextUntilThePageIsReadyAndSendsItAgainAfterAReload() async throws {
        let controller = HephonAgentController(
            organization: "suppy-demo", store: "branch-7",
            text: HephonText(welcomeTitle: "What can we get you?", labels: .init(checkout: "Go to checkout"))
        )
        // Text is never on the chat URL.
        XCTAssertEqual(
            controller.url.absoluteString,
            "\(hephon)/c/suppy-demo?store=branch-7&embed=ios&sdk=\(HephonCommerceSDK.version)"
        )
        let web = FakeWebView()
        controller.attach(web)
        controller.setText(HephonText(placeholder: "Ask Suppy", labels: .init(newChat: "New conversation")))
        await settle()
        XCTAssertEqual(web.delivered, [])

        try post(controller, Fixture.page("ready"))
        await until { web.delivered.count == 2 }
        XCTAssertEqual(web.types, ["text", "text"])
        XCTAssertEqual(try data(web.delivered[0], "text"), [
            "welcomeTitle": "What can we get you?", "labels": ["checkout": "Go to checkout"],
        ])
        XCTAssertEqual(try data(web.delivered[1], "text"), [
            "placeholder": "Ask Suppy", "labels": ["newChat": "New conversation"],
        ])

        // Ready: sent at once, only what was set.
        controller.setText(HephonText(tagline: "Your shopping buddy"))
        await until { web.delivered.count == 3 }
        XCTAssertEqual(try data(web.delivered[2], "text"), ["tagline": "Your shopping buddy"])

        // A reload is a new page: it gets everything, merged, the labels key by key.
        controller.reload()
        controller.didStartLoading()
        await settle()
        XCTAssertEqual(web.delivered.count, 3)
        try post(controller, Fixture.page("ready", ["id": "ready-2"]))
        await until { web.delivered.count == 4 }
        XCTAssertEqual(try data(web.delivered[3], "text"), [
            "welcomeTitle": "What can we get you?", "placeholder": "Ask Suppy", "tagline": "Your shopping buddy",
            "labels": ["checkout": "Go to checkout", "newChat": "New conversation"],
        ])
        // And again after the next one, with what was set in between.
        controller.setText(HephonText(labels: .init(checkout: "Pay")))
        await until { web.delivered.count == 5 }
        XCTAssertEqual(try data(web.delivered[4], "text"), ["labels": ["checkout": "Pay"]])
        controller.didStartLoading()
        try post(controller, Fixture.page("ready", ["id": "ready-3"]))
        await until { web.delivered.count == 6 }
        XCTAssertEqual(
            (try data(web.delivered[5], "text"))["labels"] as? NSDictionary,
            ["checkout": "Pay", "newChat": "New conversation"]
        )
    }

    func testAChatWithNoTextOrSetAppearanceSendsNothingAfterAReload() async throws {
        let (controller, web) = open(launch: nil)
        try post(controller, Fixture.page("ready"))
        controller.didStartLoading()
        try post(controller, Fixture.page("ready", ["id": "ready-2"]))
        await settle()
        // The open-time appearance is on the chat URL, which the reload kept.
        XCTAssertEqual(web.delivered, [])
    }

    func testDropsSetAppearanceOnceDisposed() async throws {
        let (controller, web) = open(launch: nil)
        try post(controller, Fixture.page("ready"))
        controller.dispose()
        controller.setAppearance(look)
        controller.setText(HephonText(tagline: "Late"))
        await settle()
        XCTAssertEqual(web.delivered, [])
    }

    /// The overrides are ordinary parameters of the chat URL: a load after the first drops the
    /// spent token and nothing else.
    func testAReloadKeepsTheOverrides() throws {
        let (controller, web) = open(launch: nil)
        XCTAssertEqual(
            controller.url.absoluteString,
            "\(hephon)/c/suppy-demo?store=branch-7&embed=ios&sdk=\(HephonCommerceSDK.version)&locale=ar&\(params)"
        )
        // Before the chat was ever ready, and after.
        controller.didFailLoading(URLError(.notConnectedToInternet))
        controller.reload()
        XCTAssertEqual(web.loads, [controller.url, controller.url])
        try post(controller, Fixture.page("ready"))
        controller.reload()
        XCTAssertEqual(web.loads.last, controller.url)
        // Inside the chat, where the page kept them on its URL.
        let support = URL(string: "\(hephon)/c/suppy-demo?view=support&\(params)")
        web.url = support
        controller.reload()
        XCTAssertEqual(web.loads.last?.absoluteString, "\(hephon)/c/suppy-demo?view=support&\(params)&store=branch-7")
    }

    func testARelaunchWithAFreshTokenKeepsTheOverrides() async throws {
        let (controller, web) = open(launch: .token("token-1"))
        controller.onSessionExpired = { [unowned self] in
            asked += 1
            return "fresh+token"
        }
        try post(controller, Fixture.page("ready"))
        // The session is in the web view: the spent token goes, the overrides stay.
        controller.reload()
        XCTAssertEqual(
            web.loads.last?.absoluteString,
            "\(hephon)/c/suppy-demo?embed=ios&sdk=\(HephonCommerceSDK.version)&locale=ar&\(params)&store=branch-7"
        )
        // iOS ended the page's process: a fresh token, and the same overrides.
        controller.didTerminate()
        await until { web.loads.count == 3 }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(
            web.loads.last?.absoluteString,
            "\(hephon)/c/suppy-demo?lt=fresh%2Btoken&embed=ios&sdk=\(HephonCommerceSDK.version)&locale=ar&\(params)"
        )
    }

    func testRelaunchURLLeavesTheOverridesAsTheyAre() {
        let url = URL(string: "\(hephon)/c/suppy?lt=a.b.c&embed=ios&sdk=1.2.0&\(params)")!
        XCTAssertEqual(
            HephonNavigation.relaunchURL(url, store: "s1").absoluteString,
            "\(hephon)/c/suppy?embed=ios&sdk=1.2.0&\(params)&store=s1"
        )
        XCTAssertEqual(
            HephonNavigation.relaunchURL(url, launchToken: "d.e.f").absoluteString,
            "\(hephon)/c/suppy?lt=d.e.f&embed=ios&sdk=1.2.0&\(params)"
        )
    }

    private func post(_ controller: HephonAgentController, _ json: String) {
        controller.receive(json, isMainFrame: true, origin: hephon)
    }
}
