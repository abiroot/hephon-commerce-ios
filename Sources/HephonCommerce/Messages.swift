import Foundation

/// Bridge envelope v1: the messages the Hephon chat page and your app exchange. Every message
/// is `{v: 1, id, type, ts, data}`; `id` is the idempotency key (events arrive at least once).
///
/// Mirrors the `@repo/embed` schemas. `Tests/HephonCommerceTests/Fixtures/bridge_v1.json` and
/// `preload_v1.json` and `appearance_v1.json` are the shared contract both sides are tested against.
public let hephonBridgeVersion = 1

/// Who changed the cart.
public enum CartOrigin: String, Sendable, Decodable {
    /// The agent, from a tool call.
    case agent
    /// The shopper, with the steppers in the chat.
    case shopper
    /// Your app, through `sendCartSnapshot`. Ignore your own echo.
    case host
}

/// One cart line as it changed. Prices are decimal strings in the store currency, so nothing
/// is lost to floating point.
public struct CartItem: Sendable, Decodable, Equatable {
    /// Your item id (the retailer's catalog id).
    public let itemId: String
    public let quantity: Int
    public let previousQuantity: Int
    public let unitPrice: String
    public let currency: String
    public let title: String
    /// `SIMILAR`, `SPECIFIC` or `NONE` when the shopper chose one.
    public let substitution: String?
    /// The item the shopper accepts instead, when `substitution` is `SPECIFIC`.
    public let substituteItemId: String?
}

/// A cart line was added, updated or removed.
public struct CartItemEvent: Sendable, Decodable, Equatable {
    /// Your store (branch) id.
    public let storeId: String
    public let conversationId: String
    public let origin: CartOrigin
    public let item: CartItem
}

/// The cart was emptied in one go.
public struct CartCleared: Sendable, Decodable, Equatable {
    public let storeId: String
    public let conversationId: String
    /// The lines that were in the cart, each with `quantity` 0.
    public let removed: [CartItem]
}

/// One line of the cart handed over at checkout.
public struct CartHandoffItem: Sendable, Decodable, Equatable {
    public let itemId: String
    public let quantity: Int
    public let unitPrice: String
    public let substitution: String?
    /// The item the shopper accepts instead, when `substitution` is `SPECIFIC`.
    public let substituteItemId: String?
}

/// The basket the shopper wants to buy, in your ids. Open your own checkout with it.
public struct CartHandoff: Sendable, Decodable, Equatable {
    public let storeId: String
    public let currency: String
    /// Decimal string in `currency`.
    public let total: String
    public let conversationId: String
    public let items: [CartHandoffItem]
    /// The `sub` of the launch token, when you sent one.
    public let externalShopperId: String?
    /// The `hsid` of the launch token, when you sent one.
    public let hostSessionId: String?
}

/// The chat is open and listening.
public struct HephonReady: Sendable, Decodable, Equatable {
    public let orgSlug: String
    public let storeId: String
    /// Host messages the page accepts, like `cart.snapshot`.
    public let capabilities: [String]
    /// Set when an earlier conversation was resumed.
    public let conversationId: String?
    public let hostSessionId: String?
}

/// The agent handed the conversation to a person on the retailer's team.
public struct HephonHandoff: Sendable, Decodable, Equatable {
    public let conversationId: String
    public let reason: String?
}

/// The shopper opened a product in the chat. Show your own product page if you prefer.
public struct OpenProduct: Sendable, Decodable, Equatable {
    public let itemId: String
    public let storeId: String
}

/// How long the chat took to open, for `HephonAgentController.onTiming`.
public struct HephonOpenTiming: Sendable, Decodable, Equatable {
    /// Milliseconds from the moment the view began to appear until the chat was usable and on
    /// screen. Nil when the page could not confirm a frame was drawn.
    public let open: Int?
    /// The chat was already loaded when it was shown (`preload()`, or a reopen).
    public let preloaded: Bool
}

/// How a cart line changed: `cart.item_added`, `cart.item_updated` or `cart.item_removed`.
public enum CartChange: Sendable, Equatable {
    case added, updated, removed
}

/// A message from the chat page. `HephonAgentController` turns these into its callbacks.
public enum PageMessage: Sendable, Equatable {
    case ready(HephonReady)
    case cartItem(CartChange, CartItemEvent)
    case cartCleared(CartCleared)
    case checkout(CartHandoff)
    case handoff(HephonHandoff)
    case openProduct(OpenProduct)
    case sessionExpired
    /// Web widget only; webviews ignore it.
    case resize(height: Double)
    /// Web widget only: the chat's close button.
    case close

    /// One message as the page sent it, with its envelope.
    public struct Envelope: Sendable, Equatable {
        /// Idempotency key: the same event can arrive twice.
        public let id: String
        public let timestamp: Date
        public let message: PageMessage
    }

    /// The message in `json`, or nil when it is not a valid v1 message. Other versions,
    /// unknown types and payloads of the wrong shape are ignored, never guessed at.
    public static func parse(_ json: String) -> Envelope? {
        guard let page = PageEvent.parse(json), case let .message(message) = page.event else {
            return nil
        }
        return Envelope(id: page.id, timestamp: page.timestamp, message: message)
    }
}

/// Everything the chat page sends. The messages added since 1.0.0 are cases here and not in
/// `PageMessage`, so a `switch` over `PageMessage` written for 1.0.0 still compiles.
enum PageEvent: Sendable, Equatable {
    case message(PageMessage)
    /// The chat is drawn, before it is ready: the loading indicator can go. Since 1.1.0.
    case painted
    /// The chat became usable after being shown. Since 1.1.0.
    case timing(HephonOpenTiming)

    struct Envelope: Sendable, Equatable {
        let id: String
        let timestamp: Date
        let event: PageEvent
    }

    static func parse(_ json: String) -> Envelope? {
        let bytes = Data(json.utf8)
        let decoder = JSONDecoder()
        guard
            let header = try? decoder.decode(Header.self, from: bytes),
            header.v == hephonBridgeVersion,
            !header.id.isEmpty
        else {
            return nil
        }
        func data<T: Decodable>(_: T.Type) -> T? {
            try? decoder.decode(Payload<T>.self, from: bytes).data
        }
        var message: PageMessage?
        var event: PageEvent?
        switch header.type {
        case "ready": message = data(HephonReady.self).map(PageMessage.ready)
        case "cart.item_added": message = data(CartItemEvent.self).map { .cartItem(.added, $0) }
        case "cart.item_updated": message = data(CartItemEvent.self).map { .cartItem(.updated, $0) }
        case "cart.item_removed": message = data(CartItemEvent.self).map { .cartItem(.removed, $0) }
        case "cart.cleared": message = data(CartCleared.self).map(PageMessage.cartCleared)
        case "checkout": message = data(CartHandoff.self).map(PageMessage.checkout)
        case "handoff": message = data(HephonHandoff.self).map(PageMessage.handoff)
        case "open_product": message = data(OpenProduct.self).map(PageMessage.openProduct)
        case "session.expired": message = .sessionExpired
        case "resize":
            message = data(Resize.self).flatMap { $0.height >= 0 ? .resize(height: $0.height) : nil }
        case "close": message = .close
        case "painted": event = .painted
        case "timing":
            event = data(HephonOpenTiming.self).flatMap { ($0.open ?? 0) >= 0 ? .timing($0) : nil }
        default: break
        }
        return (event ?? message.map(PageEvent.message)).map {
            Envelope(
                id: header.id,
                timestamp: Date(timeIntervalSince1970: TimeInterval(header.ts) / 1000),
                event: $0
            )
        }
    }
}

/// The envelope: `data` must be an object for every type, even the empty ones.
private struct Header: Decodable {
    let v: Int
    let id: String
    let type: String
    let ts: Int64
    let data: AnyObjectShape
}

private struct Payload<T: Decodable>: Decodable {
    let data: T
}

private struct Resize: Decodable {
    let height: Double
}

/// Accepts any JSON object and nothing else.
private struct AnyObjectShape: Decodable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: Key.self)
    }
}

/// One line of your app's cart, for `sendCartSnapshot`.
public struct CartSnapshotItem: Sendable, Encodable, Equatable {
    public let itemId: String
    /// 0 removes the line.
    public let quantity: Int

    public init(itemId: String, quantity: Int) {
        precondition(quantity >= 0, "quantity cannot be negative")
        self.itemId = itemId
        self.quantity = quantity
    }
}

/// Color scheme for `setTheme`.
public enum HephonScheme: String, Sendable, Encodable {
    case light, dark
}

/// A message from your app to the chat page.
public struct HostMessage: Sendable, Equatable {
    public let type: String
    public let id: String
    public let timestamp: Date
    let data: Body

    enum Body: Sendable, Equatable {
        case cartSnapshot([CartSnapshotItem])
        case sessionLaunch(String)
        case theme(HephonScheme)
        case focus
        case visibility(shown: Bool, at: Int64?)
        case appearance(HephonAppearance)
        case text(HephonText)
    }

    private init(_ type: String, _ data: Body, id: String?, timestamp: Date?) {
        self.type = type
        self.data = data
        self.id = id ?? UUID().uuidString.lowercased()
        self.timestamp = timestamp ?? Date()
    }

    /// Your cart, so the agent works from what the shopper already has. Each listed item's
    /// quantity is set (0 removes it); an empty list empties the chat's basket.
    public static func cartSnapshot(
        _ items: [CartSnapshotItem], id: String? = nil, timestamp: Date? = nil
    ) -> HostMessage {
        HostMessage("cart.snapshot", .cartSnapshot(items), id: id, timestamp: timestamp)
    }

    /// A fresh launch token, after `session.expired` or a sign-in.
    public static func sessionLaunch(
        _ launchToken: String, id: String? = nil, timestamp: Date? = nil
    ) -> HostMessage {
        HostMessage("session.launch", .sessionLaunch(launchToken), id: id, timestamp: timestamp)
    }

    /// Your app's color scheme. Accepted; the chat stays light for now.
    public static func theme(
        _ scheme: HephonScheme, id: String? = nil, timestamp: Date? = nil
    ) -> HostMessage {
        HostMessage("theme", .theme(scheme), id: id, timestamp: timestamp)
    }

    /// Puts the cursor in the message box.
    public static func focus(id: String? = nil, timestamp: Date? = nil) -> HostMessage {
        HostMessage("focus", .focus, id: id, timestamp: timestamp)
    }

    /// Whether the chat is on screen. `at` is when the view began to appear, sent once per show:
    /// the page measures the open from it. `HephonAgentController` sends these itself.
    public static func visibility(
        _ shown: Bool, at: Date? = nil, id: String? = nil, timestamp: Date? = nil
    ) -> HostMessage {
        HostMessage("visibility", .visibility(shown: shown, at: at.map(milliseconds)), id: id, timestamp: timestamp)
    }

    /// What your app restyles in the chat: only the fields that are set are sent, and the chat
    /// merges them over what your app sent before. A flag is sent as true or false. Ignored
    /// when the retailer switched app changes off (`ready` then lists no `appearance`
    /// capability). Since 1.2.0.
    public static func appearance(
        _ appearance: HephonAppearance, id: String? = nil, timestamp: Date? = nil
    ) -> HostMessage {
        HostMessage("appearance", .appearance(appearance), id: id, timestamp: timestamp)
    }

    /// The words your app changes in the chat: only the fields that are set are sent (`labels`
    /// only when a label is), and the chat merges them over what your app sent before. Ignored
    /// when the retailer switched app changes off (`ready` then lists no `text` capability).
    /// Since 1.2.0.
    public static func text(_ text: HephonText, id: String? = nil, timestamp: Date? = nil) -> HostMessage {
        HostMessage("text", .text(text), id: id, timestamp: timestamp)
    }

    /// The envelope as JSON text, what the page's `window.hephon.receive` takes.
    public func json() -> String {
        let envelope = Outgoing(
            v: hephonBridgeVersion,
            id: id,
            type: type,
            ts: milliseconds(timestamp),
            data: data
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Strings, integers and arrays of them always encode.
        return String(decoding: try! encoder.encode(envelope), as: UTF8.self)
    }
}

/// `date` in whole milliseconds since 1970, the bridge's clock.
private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
}

private struct Outgoing: Encodable {
    let v: Int
    let id: String
    let type: String
    let ts: Int64
    let data: HostMessage.Body
}

extension HostMessage.Body: Encodable {
    private enum Keys: String, CodingKey {
        case items, launchToken, scheme, shown, at
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .cartSnapshot(items): try container.encode(items, forKey: .items)
        case let .sessionLaunch(token): try container.encode(token, forKey: .launchToken)
        case let .theme(scheme): try container.encode(scheme, forKey: .scheme)
        case .focus: break
        case let .visibility(shown, at):
            try container.encode(shown, forKey: .shown)
            try container.encodeIfPresent(at, forKey: .at)
        case let .appearance(appearance): try appearance.encodeData(to: encoder)
        case let .text(text): try text.encodeData(to: encoder)
        }
    }
}
