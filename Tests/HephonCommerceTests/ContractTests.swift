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
        // Milk is item 7309008 in branch 7 and 48213 in the catalog.
        XCTAssertEqual(added.item.itemId, "7309008")
        XCTAssertEqual(added.item.catalogId, "48213")
        XCTAssertEqual(added.item.unitPrice, "1.50")
        XCTAssertEqual(added.item.substitution, "SIMILAR")
        XCTAssertNil(added.item.substituteItemId)
        XCTAssertEqual(added.item.imageUrl, "https://cdn.example.com/products/48213.jpg")

        guard case let .cartItem(.updated, updated) = parsed[3].message else {
            return XCTFail("not item_updated: \(parsed[3])")
        }
        XCTAssertEqual(updated.origin, .shopper)
        XCTAssertEqual(updated.item.previousQuantity, 2)
        XCTAssertEqual(updated.item.itemId, "7309008")
        XCTAssertEqual(updated.item.catalogId, "48213")
        XCTAssertEqual(updated.item.substituteItemId, "7309009")

        guard case let .cartItem(.removed, removed) = parsed[4].message else {
            return XCTFail("not item_removed: \(parsed[4])")
        }
        XCTAssertEqual(removed.origin, .host)
        XCTAssertEqual(removed.item.quantity, 0)
        // A product with no image carries none.
        XCTAssertNil(removed.item.imageUrl)
        XCTAssertEqual(removed.item.itemId, "7309008")
        XCTAssertEqual(removed.item.catalogId, "48213")

        guard case let .cartCleared(cleared) = parsed[5].message else {
            return XCTFail("not cleared: \(parsed[5])")
        }
        // One id everywhere: both are the same.
        XCTAssertEqual(cleared.removed.map(\.itemId), ["51007", "60321"])
        XCTAssertEqual(cleared.removed.map(\.catalogId), ["51007", "60321"])
        XCTAssertEqual(cleared.removed[1].substitution, "NONE")

        guard case let .checkout(cart) = parsed[6].message else {
            return XCTFail("not checkout: \(parsed[6])")
        }
        XCTAssertEqual(cart.total, "21.25")
        XCTAssertEqual(cart.currency, "USD")
        XCTAssertEqual(cart.externalShopperId, "u-991")
        XCTAssertEqual(cart.hostSessionId, "host-session-42")
        XCTAssertEqual(cart.items.map(\.quantity), [2, 2])
        XCTAssertEqual(cart.items.map(\.itemId), ["7309008", "60321"])
        XCTAssertEqual(cart.items.map(\.catalogId), ["48213", "60321"])
        XCTAssertEqual(cart.items[1].substituteItemId, "60322")

        XCTAssertEqual(
            parsed[7].message,
            .handoff(HephonHandoff(conversationId: "cm1conversation0001", reason: "Asked for a person"))
        )
        XCTAssertEqual(parsed[8].message, .openProduct(OpenProduct(itemId: "7309008", catalogId: "48213", storeId: "branch-7")))
        XCTAssertEqual(parsed[9].message, .sessionExpired)
        XCTAssertEqual(parsed[10].message, .resize(height: 640))
        XCTAssertEqual(parsed[11].message, .close)
    }

    func testRejectsWhatIsNotBridgeV1() throws {
        let rejected = try Fixture.list("bridge_v1", "rejected")
        XCTAssertEqual(rejected.count, 7)
        for message in rejected {
            XCTAssertNil(PageMessage.parse(Fixture.json(message)), "accepted \(message["$comment"] ?? message)")
        }
        // A product without either of its ids is no product.
        for (type, path) in [
            ("cart.item_added", ["item"]), ("cart.item_updated", ["item"]), ("cart.item_removed", ["item"]),
            ("cart.cleared", ["removed"]), ("checkout", ["items"]), ("open_product", []),
        ] {
            for id in ["itemId", "catalogId"] {
                let message = try XCTUnwrap(
                    Fixture.list("bridge_v1", "pageToHost").first { $0["type"] as? String == type }
                )
                var data = try XCTUnwrap(message["data"] as? [String: Any])
                if let key = path.first, var item = data[key] as? [String: Any] {
                    item[id] = nil
                    data[key] = item
                } else if let key = path.first, var lines = data[key] as? [[String: Any]] {
                    lines[0][id] = nil
                    data[key] = lines
                } else {
                    data[id] = nil
                }
                XCTAssertNotNil(PageMessage.parse(Fixture.json(message)), type)
                XCTAssertNil(
                    PageMessage.parse(Fixture.json(message.merging(["data": data]) { $1 })),
                    "accepted \(type) without \(id)"
                )
            }
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
                // The fixture's two lines, one from each initialiser.
                .cartSnapshot(
                    [
                        CartSnapshotItem(itemId: "7309008", quantity: 2),
                        CartSnapshotItem(catalogId: "51007", quantity: 0),
                    ],
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

    func testASnapshotLineNamesItsItemByExactlyOneId() throws {
        let json = HostMessage.cartSnapshot([
            CartSnapshotItem(itemId: "7309008", quantity: 2),
            CartSnapshotItem(catalogId: "51007", quantity: 0),
        ]).json()
        // The id that is not set is left out, never null or empty.
        XCTAssertTrue(
            json.contains(#""items":[{"itemId":"7309008","quantity":2},{"catalogId":"51007","quantity":0}]"#),
            json
        )
        XCTAssertFalse(json.contains("null"))

        let byItem = CartSnapshotItem(itemId: "7309008", quantity: 2)
        XCTAssertEqual(byItem.itemId, "7309008")
        XCTAssertNil(byItem.catalogId)
        let byCatalog = CartSnapshotItem(catalogId: "51007", quantity: 0)
        XCTAssertNil(byCatalog.itemId)
        XCTAssertEqual(byCatalog.catalogId, "51007")
        XCTAssertNotEqual(CartSnapshotItem(itemId: "51007", quantity: 0), byCatalog)

        // A line with both ids or neither has no initialiser. What the two there are stop on
        // (`precondition`, which a test cannot survive) is this check.
        XCTAssertEqual(CartSnapshotItem.problem(id: "", quantity: 2), "a cart line needs the id of its item")
        XCTAssertEqual(CartSnapshotItem.problem(id: "7309008", quantity: -1), "quantity cannot be negative")
        XCTAssertNil(CartSnapshotItem.problem(id: "7309008", quantity: 0))
        // The fixture's refused snapshots are the two shapes that cannot be built.
        let refused = try Fixture.list("bridge_v1", "rejected").filter { $0["type"] as? String == "cart.snapshot" }
        let lines = try refused.flatMap {
            try XCTUnwrap(($0["data"] as? [String: Any])?["items"] as? [[String: Any]])
        }
        XCTAssertEqual(lines.map { [$0["itemId"] != nil, $0["catalogId"] != nil] }, [[false, false], [true, true]])
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
