import Foundation

/// Bridge envelope v1: the messages the Hephon chat page and your app exchange. Every message
/// is `{v: 1, id, type, ts, data}`; `id` is the idempotency key (events arrive at least once).
///
/// Mirrors the `@repo/embed` schemas. `Tests/HephonCommerceTests/Fixtures/bridge_v1.json` and
/// `preload_v1.json`, `appearance_v1.json` and `control_v1.json` are the shared contract both sides
/// are tested against.
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
    /// The product's id in the store of the session: what a cart line or an order line there
    /// is keyed on. On a platform with a row per store it is that row's id; on one with one id
    /// per product it equals `catalogId`.
    public let itemId: String
    /// The product's id in the catalog, the same in every store. Since 2.0.0.
    public let catalogId: String
    public let quantity: Int
    public let previousQuantity: Int
    public let unitPrice: String
    public let currency: String
    public let title: String
    /// The product's main image, an absolute URL, when it has one. Since 2.1.0.
    public let imageUrl: String?
    /// `SIMILAR`, `SPECIFIC` or `NONE` when the shopper chose one.
    public let substitution: String?
    /// The item the shopper accepts instead, by its id in the same store, when `substitution`
    /// is `SPECIFIC`.
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
    /// The product's id in the store of the session: what a cart line or an order line there
    /// is keyed on. On a platform with a row per store it is that row's id; on one with one id
    /// per product it equals `catalogId`.
    public let itemId: String
    /// The product's id in the catalog, the same in every store. Since 2.0.0.
    public let catalogId: String
    public let quantity: Int
    public let unitPrice: String
    public let substitution: String?
    /// The item the shopper accepts instead, by its id in the same store, when `substitution`
    /// is `SPECIFIC`.
    public let substituteItemId: String?
}

/// The basket the shopper wants to buy, in your ids: each line by `itemId`, with its `catalogId`. Open your own checkout with it.
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
    /// The product's id in the store of the session: what a cart line or an order line there
    /// is keyed on. On a platform with a row per store it is that row's id; on one with one id
    /// per product it equals `catalogId`.
    public let itemId: String
    /// The product's id in the catalog, the same in every store. Since 2.0.0.
    public let catalogId: String
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

/// What the chat is doing, for `HephonAgentController.onStateChange`: posted whenever it
/// changes, so your app's own header or buttons can follow it. Since 2.2.0.
public struct HephonChatState: Sendable, Decodable, Equatable {
    /// Which screen the chat shows.
    public enum View: String, Sendable, Decodable, CaseIterable {
        /// The first screen, before any message.
        case welcome
        /// A conversation with at least one message.
        case conversation
    }

    public let view: View
    /// A reply is on its way. A `sendMessage` now is dropped.
    public let busy: Bool
    /// The chat's basket is open.
    public let basketOpen: Bool
    /// Units in the basket.
    public let itemCount: Int
    /// The conversation, once there is one.
    public let conversationId: String?

    public init(view: View, busy: Bool, basketOpen: Bool, itemCount: Int, conversationId: String? = nil) {
        self.view = view
        self.busy = busy
        self.basketOpen = basketOpen
        self.itemCount = itemCount
        self.conversationId = conversationId
    }
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
    /// The chat's close button (web widget), or its back arrow (`showBack`, since 2.2.0).
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
    /// What the chat is doing changed. Since 2.2.0.
    case state(HephonChatState)

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
        case "state":
            event = data(HephonChatState.self).flatMap { $0.itemCount >= 0 ? .state($0) : nil }
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

/// One line of your app's cart, for `sendCartSnapshot`. It names its item by the id your cart
/// holds: `itemId` (the product in this store, as cart events give it), or `catalogId` for a
/// cart keyed on catalog ids. One of the two, never both.
public struct CartSnapshotItem: Sendable, Encodable, Equatable {
    /// The product's id in the store of the session. Nil for a line made with `catalogId`.
    public let itemId: String?
    /// The product's id in the catalog. Nil for a line made with `itemId`. Since 2.0.0.
    public let catalogId: String?
    /// 0 removes the line.
    public let quantity: Int

    /// A line by the id your cart holds, as cart events give it. An empty id or a negative
    /// quantity stops here (`precondition`).
    public init(itemId: String, quantity: Int) {
        if let problem = Self.problem(id: itemId, quantity: quantity) {
            preconditionFailure(problem)
        }
        self.itemId = itemId
        catalogId = nil
        self.quantity = quantity
    }

    /// A line by catalog id, for a cart keyed on catalog ids. An empty id or a negative
    /// quantity stops here (`precondition`). Since 2.0.0.
    public init(catalogId: String, quantity: Int) {
        if let problem = Self.problem(id: catalogId, quantity: quantity) {
            preconditionFailure(problem)
        }
        itemId = nil
        self.catalogId = catalogId
        self.quantity = quantity
    }

    /// Why an `init` refuses these arguments, nil when it takes them.
    static func problem(id: String, quantity: Int) -> String? {
        if quantity < 0 {
            return "quantity cannot be negative"
        }
        return id.isEmpty ? "a cart line needs the id of its item" : nil
    }
}

/// Color scheme for `setTheme`.
public enum HephonScheme: String, Sendable, Encodable {
    case light, dark
}

/// A suggestion on the chat's welcome screen, for `HephonAgentController.setStarters`.
/// Tapping it sends `prompt`, or `label` when there is none. Since 2.2.0.
///
/// Both are trimmed. A `label` of 1 to 60 characters and a `prompt` of 1 to 300 are what the
/// chat takes: `setStarters` refuses a list with any other (`isValid`).
public struct HephonStarter: Sendable, Equatable, Encodable {
    /// What the suggestion says.
    public let label: String
    /// What tapping it sends as the shopper's message; `label` when nil.
    public let prompt: String?

    public init(label: String, prompt: String? = nil) {
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// At most this many suggestions on the welcome screen.
    public static let maxCount = 6

    /// Whether the chat takes this suggestion: a label of 1 to 60 characters, and a prompt of
    /// 1 to 300 when there is one.
    public var isValid: Bool {
        fits(label, 60) && (prompt.map { fits($0, 300) } ?? true)
    }
}

/// A kind of product a chat never shows, for `HephonAgentController.setRestrictions`. What
/// your app excludes is added to what the retailer excludes: an app can never show a kind the
/// retailer hides. Since 2.2.0.
public enum HephonRestriction: String, Sendable, Encodable, CaseIterable {
    case alcohol
    /// Alcohol-free versions of alcoholic drinks (alcohol-free beer, wine).
    case alcoholFree = "alcohol_free"
    case pork
    case tobacco
}

/// The longest message `HephonAgentController.sendMessage` sends. Since 2.2.0.
public let hephonMaxMessageLength = 2000

/// Whether `value` is 1 to `max` characters, counted as the chat counts them (UTF-16 units).
private func fits(_ value: String, _ max: Int) -> Bool {
    !value.isEmpty && value.utf16.count <= max
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
        case chatSend(String)
        case empty
        case starters([HephonStarter])
        case locale(String)
        case restrictions([HephonRestriction])
    }

    private init(_ type: String, _ data: Body, id: String?, timestamp: Date?) {
        self.type = type
        self.data = data
        self.id = id ?? UUID().uuidString.lowercased()
        self.timestamp = timestamp ?? Date()
    }

    /// Your cart, so the agent works from what the shopper already has. Each listed item's
    /// quantity is set (0 removes it); an empty list empties the chat's basket. A line names
    /// its item by `itemId`, or by `catalogId` for a cart keyed on catalog ids.
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

    /// `text` sent as the shopper's message, as if typed. Nil when it is empty once trimmed or
    /// longer than `hephonMaxMessageLength`. The chat drops it while a reply is on its way
    /// (`HephonChatState.busy`). Since 2.2.0.
    public static func chatSend(_ text: String, id: String? = nil, timestamp: Date? = nil) -> HostMessage? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fits(text, hephonMaxMessageLength) else {
            return nil
        }
        return HostMessage("chat.send", .chatSend(text), id: id, timestamp: timestamp)
    }

    /// Starts a new conversation with an empty chat basket (your own cart is not touched). Since 2.2.0.
    public static func chatNew(id: String? = nil, timestamp: Date? = nil) -> HostMessage {
        HostMessage("chat.new", .empty, id: id, timestamp: timestamp)
    }

    /// Opens the chat's basket. Since 2.2.0.
    public static func basketOpen(id: String? = nil, timestamp: Date? = nil) -> HostMessage {
        HostMessage("basket.open", .empty, id: id, timestamp: timestamp)
    }

    /// Closes the chat's basket. Since 2.2.0.
    public static func basketClose(id: String? = nil, timestamp: Date? = nil) -> HostMessage {
        HostMessage("basket.close", .empty, id: id, timestamp: timestamp)
    }

    /// The welcome screen's suggestions, in place of the retailer's; an empty list brings the
    /// retailer's back. Nil for more than `HephonStarter.maxCount`, or one that is not
    /// `isValid`. Ignored when the retailer switched app changes off (`ready` then lists no
    /// `starters` capability). Since 2.2.0.
    public static func starters(
        _ items: [HephonStarter], id: String? = nil, timestamp: Date? = nil
    ) -> HostMessage? {
        guard items.count <= HephonStarter.maxCount, items.allSatisfy(\.isValid) else {
            return nil
        }
        return HostMessage("starters", .starters(items), id: id, timestamp: timestamp)
    }

    /// The app's language, a BCP 47 tag like `ar` or `ar-AE`: the chat's own words, and the
    /// reply language for a message that could be either. Nil for anything that is not a
    /// tag. Since 2.2.0.
    public static func locale(_ locale: String, id: String? = nil, timestamp: Date? = nil) -> HostMessage? {
        guard isLocale(locale) else {
            return nil
        }
        return HostMessage("locale", .locale(locale), id: id, timestamp: timestamp)
    }

    /// Kinds of product this chat never shows, added to the retailer's. Each kind is sent once.
    /// Since 2.2.0.
    public static func restrictions(
        _ kinds: [HephonRestriction], id: String? = nil, timestamp: Date? = nil
    ) -> HostMessage {
        var seen = Set<HephonRestriction>()
        let unique = kinds.filter { seen.insert($0).inserted }
        return HostMessage("restrictions", .restrictions(unique), id: id, timestamp: timestamp)
    }

    /// Whether `value` is a BCP 47 tag the chat takes, like `ar` or `ar-AE`.
    public static func isLocale(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
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
        case items, launchToken, scheme, shown, at, text, locale, exclude
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
        case let .chatSend(text): try container.encode(text, forKey: .text)
        case .empty: break
        case let .starters(items): try container.encode(items, forKey: .items)
        case let .locale(locale): try container.encode(locale, forKey: .locale)
        case let .restrictions(kinds): try container.encode(kinds, forKey: .exclude)
        }
    }
}
