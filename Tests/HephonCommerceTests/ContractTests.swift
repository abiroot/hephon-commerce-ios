import Foundation
@testable import HephonCommerce
import XCTest

/// bridge_v1.json and host_v1.json, the contract every Hephon SDK is tested against.
final class BridgeContractTests: XCTestCase {
    func testParsesEveryPageMessage() throws {
        let messages = try Fixture.list("bridge_v1", "pageToHost")
        let parsed = try messages.map { message in
            try XCTUnwrap(PageMessage.parse(Fixture.json(message)), "\(message["type"] ?? "?") did not parse")
        }
        XCTAssertEqual(parsed.map(\.id), messages.map { $0["id"] as? String })

        guard case let .ready(ready) = parsed[0].message else {
            return XCTFail("not ready: \(parsed[0])")
        }
        XCTAssertEqual(ready.orgSlug, "suppy-demo")
        XCTAssertEqual(ready.conversationId, "cm1conversation0001")
        XCTAssertEqual(ready.capabilities, ["cart.snapshot", "session.launch", "theme", "focus"])
        XCTAssertEqual(parsed[0].timestamp, Date(timeIntervalSince1970: 1_791_374_400))
        XCTAssertEqual(
            parsed[1].message,
            .ready(HephonReady(
                orgSlug: "suppy-demo", storeId: "branch-7", capabilities: [],
                conversationId: nil, hostSessionId: nil
            ))
        )

        guard case let .cartItem(.added, added) = parsed[2].message else {
            return XCTFail("not item_added: \(parsed[2])")
        }
        XCTAssertEqual(added.origin, .agent)
        XCTAssertEqual(added.item.itemId, "48213")
        XCTAssertEqual(added.item.unitPrice, "1.50")
        XCTAssertEqual(added.item.substitution, "SIMILAR")
        XCTAssertNil(added.item.substituteItemId)

        guard case let .cartItem(.updated, updated) = parsed[3].message else {
            return XCTFail("not item_updated: \(parsed[3])")
        }
        XCTAssertEqual(updated.origin, .shopper)
        XCTAssertEqual(updated.item.previousQuantity, 2)
        XCTAssertEqual(updated.item.substituteItemId, "48214")

        guard case let .cartItem(.removed, removed) = parsed[4].message else {
            return XCTFail("not item_removed: \(parsed[4])")
        }
        XCTAssertEqual(removed.origin, .host)
        XCTAssertEqual(removed.item.quantity, 0)

        guard case let .cartCleared(cleared) = parsed[5].message else {
            return XCTFail("not cleared: \(parsed[5])")
        }
        XCTAssertEqual(cleared.removed.map(\.itemId), ["51007", "60321"])
        XCTAssertEqual(cleared.removed[1].substitution, "NONE")

        guard case let .checkout(cart) = parsed[6].message else {
            return XCTFail("not checkout: \(parsed[6])")
        }
        XCTAssertEqual(cart.total, "21.25")
        XCTAssertEqual(cart.currency, "USD")
        XCTAssertEqual(cart.externalShopperId, "u-991")
        XCTAssertEqual(cart.hostSessionId, "host-session-42")
        XCTAssertEqual(cart.items.map(\.quantity), [2, 2])
        XCTAssertEqual(cart.items[1].substituteItemId, "60322")

        XCTAssertEqual(
            parsed[7].message,
            .handoff(HephonHandoff(conversationId: "cm1conversation0001", reason: "Asked for a person"))
        )
        XCTAssertEqual(parsed[8].message, .openProduct(OpenProduct(itemId: "48213", storeId: "branch-7")))
        XCTAssertEqual(parsed[9].message, .sessionExpired)
        XCTAssertEqual(parsed[10].message, .resize(height: 640))
        XCTAssertEqual(parsed[11].message, .close)
    }

    func testRejectsWhatIsNotBridgeV1() throws {
        for message in try Fixture.list("bridge_v1", "rejected") {
            XCTAssertNil(PageMessage.parse(Fixture.json(message)), "accepted \(message["$comment"] ?? message)")
        }
        let close = try Fixture.page("close")
        for bad in [
            "not json",
            "[]",
            #"{"type":"hephon-commerce:cart","cart":{}}"#,
            try Fixture.page("close", ["id": ""]),
            try Fixture.page("close", ["data": []]),
            try Fixture.page("close", ["ts": "1791374410000"]),
            try Fixture.page("close", ["v": "1"]),
            try Fixture.page("resize", ["data": ["height": -1]]),
            try Fixture.page("cart.item_added", ["data": ["origin": "robot"]]),
        ] {
            XCTAssertNil(PageMessage.parse(bad), "accepted \(bad)")
        }
        XCTAssertNotNil(PageMessage.parse(close))
    }

    func testEncodesEveryHostMessageAsTheFixtureDoes() throws {
        for expected in try Fixture.list("bridge_v1", "hostToPage") {
            let id = try XCTUnwrap(expected["id"] as? String)
            let at = try Date(timeIntervalSince1970: TimeInterval(XCTUnwrap(expected["ts"] as? Int64)) / 1000)
            let data = expected["data"] as? [String: Any] ?? [:]
            let message: HostMessage = switch expected["type"] as? String {
            case "cart.snapshot":
                .cartSnapshot(
                    (data["items"] as? [[String: Any]] ?? []).map {
                        CartSnapshotItem(itemId: $0["itemId"] as? String ?? "", quantity: $0["quantity"] as? Int ?? -1)
                    },
                    id: id, timestamp: at
                )
            case "session.launch": .sessionLaunch(data["launchToken"] as? String ?? "", id: id, timestamp: at)
            case "theme": .theme(.dark, id: id, timestamp: at)
            default: .focus(id: id, timestamp: at)
            }
            let encoded = try JSONSerialization.jsonObject(with: Data(message.json().utf8))
            XCTAssertEqual(encoded as? NSDictionary, expected as NSDictionary, "\(message.type)")
        }
    }

    func testMintsLowercaseUUIDs() {
        let id = HostMessage.focus().id
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNotEqual(HostMessage.focus().id, id)
    }
}

final class HostContractTests: XCTestCase {
    func testDecidesEveryNavigation() throws {
        let navigation = try XCTUnwrap(Fixture.object("host_v1")["navigation"] as? [String: Any])
        let allowed = try Set(XCTUnwrap(navigation["allowedOrigins"] as? [String]))
        let chatPath = try XCTUnwrap(navigation["chatPath"] as? String)
        let cases = try XCTUnwrap(navigation["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 20)
        for item in cases {
            let raw = try XCTUnwrap(item["url"] as? String)
            let url = try XCTUnwrap(URL(string: raw), raw)
            let isMainFrame = try XCTUnwrap(item["isMainFrame"] as? Bool)
            XCTAssertEqual(
                HephonNavigation.decide(url, isMainFrame: isMainFrame, allowedOrigins: allowed, chatPath: chatPath)
                    .rawValue,
                item["expect"] as? String,
                "\(raw) (main frame: \(isMainFrame))"
            )
        }
    }

    func testNormalizesOrigins() throws {
        for item in try Fixture.list("host_v1", "origins") {
            let raw = try XCTUnwrap(item["url"] as? String)
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertEqual(HephonNavigation.origin(of: url), item["expect"] as? String, raw)
        }
    }

    /// WKSecurityOrigin reports port 0 for the scheme's default port.
    func testOriginFromSecurityOriginParts() {
        XCTAssertEqual(
            HephonNavigation.origin(scheme: "https", host: "commerce.hephon.ai", port: 0),
            "https://commerce.hephon.ai"
        )
        XCTAssertEqual(HephonNavigation.origin(scheme: "HTTPS", host: "Chat.Suppy.app", port: 443), "https://chat.suppy.app")
        XCTAssertEqual(HephonNavigation.origin(scheme: "http", host: "localhost", port: 3000), "http://localhost:3000")
        XCTAssertEqual(HephonNavigation.origin(scheme: "http", host: "example.com", port: 443), "http://example.com:443")
        XCTAssertNil(HephonNavigation.origin(scheme: "file", host: "", port: 0))
        XCTAssertNil(HephonNavigation.origin(scheme: "https", host: "", port: 0))
    }

    func testBuildsEveryChatURL() throws {
        for item in try Fixture.list("host_v1", "chatUrl") {
            let comment = item["$comment"] as? String ?? ""
            let token = item["launchToken"] as? String
            let code = item["launchCode"] as? String
            if token != nil, code != nil {
                // HephonLaunch is one value: a token and a code together cannot be written.
                XCTAssertEqual(item["expect"] as? String, "error", comment)
                continue
            }
            let launch: HephonLaunch? = token.map(HephonLaunch.token) ?? code.map(HephonLaunch.code)
            let url = try HephonAgentController.chatURL(
                host: XCTUnwrap(URL(string: XCTUnwrap(item["host"] as? String))),
                organization: XCTUnwrap(item["organization"] as? String),
                launch: launch,
                store: item["store"] as? String,
                locale: item["locale"] as? String,
                embed: XCTUnwrap(item["embed"] as? String),
                sdk: XCTUnwrap(item["sdk"] as? String)
            )
            let expected = try XCTUnwrap(URL(string: XCTUnwrap(item["expect"] as? String)))
            XCTAssertEqual(Parts(url), Parts(expected), comment)
        }
    }

    func testChatURLReportsThisSDK() {
        let url = HephonAgentController.chatURL(
            host: HephonAgentController.defaultHost, organization: "suppy", launch: .code("a+b/c")
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://commerce.hephon.ai/c/suppy?code=a%2Bb%2Fc&embed=ios&sdk=\(HephonCommerceSDK.version)"
        )
        XCTAssertNotNil(HephonCommerceSDK.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }
}

/// A URL as host_v1.json and appearance_v1.json compare it: origin, path and the unordered, decoded query pairs.
struct Parts: Equatable {
    let origin: String?
    let path: String
    let query: [String: String]

    init(_ url: URL) {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        origin = HephonNavigation.origin(of: url)
        path = parts?.percentEncodedPath ?? ""
        let decode = { (text: String) in text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text }
        query = Dictionary(
            uniqueKeysWithValues: (parts?.percentEncodedQuery ?? "").split(separator: "&").map { pair in
                let halves = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return (decode(halves[0]), decode(halves.count > 1 ? halves[1] : ""))
            }
        )
    }
}
