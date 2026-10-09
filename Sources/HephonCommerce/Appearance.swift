import Foundation

/// What your app restyles in the chat it opens. Every field is optional: one left nil keeps
/// what the retailer set in Hephon.
///
/// Pass it to `HephonAgentController(appearance:)` so the chat opens restyled, or to
/// `setAppearance(_:)` while it is open. The retailer can switch app changes off in
/// Configure: the chat then ignores both, and `HephonReady.capabilities` does not list
/// `appearance`.
///
/// Mirrors `Tests/HephonCommerceTests/Fixtures/appearance_v1.json`, the contract every Hephon
/// SDK is tested against.
public struct HephonAppearance: Sendable, Equatable {
    /// Light, dark, or `auto` to follow the device.
    public enum Scheme: String, Sendable, CaseIterable {
        case light, dark, auto
    }

    /// How round the chat's corners are.
    public enum Corners: String, Sendable, CaseIterable {
        case round, soft, square
    }

    /// The chat's header: plain, or filled with the primary color.
    public enum Header: String, Sendable, CaseIterable {
        case plain, brand
    }

    /// The shape of the buttons.
    public enum Buttons: String, Sendable, CaseIterable {
        case pill, rounded, square
    }

    /// The shopper's message bubble: filled with the brand color, or soft.
    public enum Bubble: String, Sendable, CaseIterable {
        case brand, soft
    }

    /// The chat's typeface. `system` is the device's own.
    public enum Font: String, Sendable, CaseIterable {
        case geist, manrope, system
    }

    /// How the conversation starters are shown.
    public enum StarterStyle: String, Sendable, CaseIterable {
        case photos, list
    }

    public let scheme: Scheme?
    /// `#RRGGBB`, like every color here. Sent as written.
    public let primaryColor: String?
    public let deepColor: String?
    public let accentColor: String?
    public let dealColor: String?
    public let corners: Corners?
    public let header: Header?
    /// The main buttons (add, checkout).
    public let ctaColor: String?
    public let headerColor: String?
    /// The shopper's message bubble.
    public let bubbleColor: String?
    /// The page behind the conversation.
    public let surfaceColor: String?
    public let buttons: Buttons?
    public let bubble: Bubble?
    public let font: Font?
    public let starterStyle: StarterStyle?
    /// What is shown. `false` hides the part, `true` shows it, nil keeps the retailer's choice.
    public let showHeader: Bool?
    public let showLogo: Bool?
    public let showBasket: Bool?
    public let showCheckout: Bool?
    public let showNewChat: Bool?
    /// The suggested replies under an answer.
    public let showFollowUps: Bool?
    /// The agent's steps while it works.
    public let showSteps: Bool?
    /// Whether tapping a product opens its sheet in the chat.
    public let productSheet: Bool?
    /// Whether a product card has its own add button.
    public let addFromCards: Bool?

    /// A color that is not `#RRGGBB` (six hex digits, either case) stops a debug build here
    /// (`assertionFailure`), so a typo is caught the first time the code runs. A release build
    /// drops that color instead: the field is nil and the chat keeps the retailer's. Check a
    /// color that is not a constant of your app with `isColor(_:)`.
    public init(
        scheme: Scheme? = nil,
        primaryColor: String? = nil,
        deepColor: String? = nil,
        accentColor: String? = nil,
        dealColor: String? = nil,
        corners: Corners? = nil,
        header: Header? = nil,
        ctaColor: String? = nil,
        headerColor: String? = nil,
        bubbleColor: String? = nil,
        surfaceColor: String? = nil,
        buttons: Buttons? = nil,
        bubble: Bubble? = nil,
        font: Font? = nil,
        starterStyle: StarterStyle? = nil,
        showHeader: Bool? = nil,
        showLogo: Bool? = nil,
        showBasket: Bool? = nil,
        showCheckout: Bool? = nil,
        showNewChat: Bool? = nil,
        showFollowUps: Bool? = nil,
        showSteps: Bool? = nil,
        productSheet: Bool? = nil,
        addFromCards: Bool? = nil
    ) {
        for (name, color) in [
            ("primaryColor", primaryColor), ("deepColor", deepColor),
            ("accentColor", accentColor), ("dealColor", dealColor),
            ("ctaColor", ctaColor), ("headerColor", headerColor),
            ("bubbleColor", bubbleColor), ("surfaceColor", surfaceColor),
        ] {
            if let color, !Self.isColor(color) {
                assertionFailure("\(name) must be #RRGGBB, got \(color)")
            }
        }
        self.scheme = scheme
        self.primaryColor = Self.color(primaryColor)
        self.deepColor = Self.color(deepColor)
        self.accentColor = Self.color(accentColor)
        self.dealColor = Self.color(dealColor)
        self.corners = corners
        self.header = header
        self.ctaColor = Self.color(ctaColor)
        self.headerColor = Self.color(headerColor)
        self.bubbleColor = Self.color(bubbleColor)
        self.surfaceColor = Self.color(surfaceColor)
        self.buttons = buttons
        self.bubble = bubble
        self.font = font
        self.starterStyle = starterStyle
        self.showHeader = showHeader
        self.showLogo = showLogo
        self.showBasket = showBasket
        self.showCheckout = showCheckout
        self.showNewChat = showNewChat
        self.showFollowUps = showFollowUps
        self.showSteps = showSteps
        self.productSheet = productSheet
        self.addFromCards = addFromCards
    }

    /// Whether `value` is a color the chat takes: `#` and six hex digits, either case.
    public static func isColor(_ value: String) -> Bool {
        value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }

    /// `value` when it is a color the chat takes, nil otherwise: what a release build keeps.
    static func color(_ value: String?) -> String? {
        value.flatMap { isColor($0) ? $0 : nil }
    }

    /// The names of the overrides, as the chat URL and the `appearance` message spell them.
    static let keys = [
        "scheme", "primaryColor", "deepColor", "accentColor", "dealColor", "corners", "header",
        "ctaColor", "headerColor", "bubbleColor", "surfaceColor",
        "buttons", "bubble", "font", "starterStyle",
        "showHeader", "showLogo", "showBasket", "showCheckout", "showNewChat",
        "showFollowUps", "showSteps", "productSheet", "addFromCards",
    ]

    /// The overrides that are set, in the order of `keys`.
    var pairs: [(String, OverrideValue)] {
        let text = { (value: String?) in value.map(OverrideValue.text) }
        let flag = { (value: Bool?) in value.map(OverrideValue.flag) }
        return zip(Self.keys, [
            text(scheme?.rawValue), text(primaryColor), text(deepColor), text(accentColor), text(dealColor),
            text(corners?.rawValue), text(header?.rawValue),
            text(ctaColor), text(headerColor), text(bubbleColor), text(surfaceColor),
            text(buttons?.rawValue), text(bubble?.rawValue), text(font?.rawValue), text(starterStyle?.rawValue),
            flag(showHeader), flag(showLogo), flag(showBasket), flag(showCheckout), flag(showNewChat),
            flag(showFollowUps), flag(showSteps), flag(productSheet), flag(addFromCards),
        ]).compactMap { key, value in value.map { (key, $0) } }
    }

    /// This appearance with every field `other` sets replaced: what the chat shows after both.
    func merging(_ other: HephonAppearance) -> HephonAppearance {
        HephonAppearance(
            scheme: other.scheme ?? scheme,
            primaryColor: other.primaryColor ?? primaryColor,
            deepColor: other.deepColor ?? deepColor,
            accentColor: other.accentColor ?? accentColor,
            dealColor: other.dealColor ?? dealColor,
            corners: other.corners ?? corners,
            header: other.header ?? header,
            ctaColor: other.ctaColor ?? ctaColor,
            headerColor: other.headerColor ?? headerColor,
            bubbleColor: other.bubbleColor ?? bubbleColor,
            surfaceColor: other.surfaceColor ?? surfaceColor,
            buttons: other.buttons ?? buttons,
            bubble: other.bubble ?? bubble,
            font: other.font ?? font,
            starterStyle: other.starterStyle ?? starterStyle,
            showHeader: other.showHeader ?? showHeader,
            showLogo: other.showLogo ?? showLogo,
            showBasket: other.showBasket ?? showBasket,
            showCheckout: other.showCheckout ?? showCheckout,
            showNewChat: other.showNewChat ?? showNewChat,
            showFollowUps: other.showFollowUps ?? showFollowUps,
            showSteps: other.showSteps ?? showSteps,
            productSheet: other.productSheet ?? productSheet,
            addFromCards: other.addFromCards ?? addFromCards
        )
    }
}

/// The words your app changes in the chat it opens. Every field is optional: one left nil
/// keeps the retailer's.
///
/// Pass it to `HephonAgentController(text:)` or to `setText(_:)`. It is sent to the chat as a
/// message, never on the chat URL. The retailer can switch app changes off in Configure: the
/// chat then ignores it, and `HephonReady.capabilities` does not list `text`.
public struct HephonText: Sendable, Equatable {
    /// The chat's button and title labels.
    public struct Labels: Sendable, Equatable {
        public let viewBasket: String?
        public let basketTitle: String?
        public let checkout: String?
        public let addToBasket: String?
        public let orderHelp: String?
        public let newChat: String?

        public init(
            viewBasket: String? = nil,
            basketTitle: String? = nil,
            checkout: String? = nil,
            addToBasket: String? = nil,
            orderHelp: String? = nil,
            newChat: String? = nil
        ) {
            self.viewBasket = viewBasket
            self.basketTitle = basketTitle
            self.checkout = checkout
            self.addToBasket = addToBasket
            self.orderHelp = orderHelp
            self.newChat = newChat
        }

        /// The names of the labels, as the `text` message spells them.
        static let keys = ["viewBasket", "basketTitle", "checkout", "addToBasket", "orderHelp", "newChat"]

        /// The labels that are set, in the order of `keys`.
        var pairs: [(String, String)] {
            zip(Self.keys, [viewBasket, basketTitle, checkout, addToBasket, orderHelp, newChat])
                .compactMap { key, value in value.map { (key, $0) } }
        }

        func merging(_ other: Labels) -> Labels {
            Labels(
                viewBasket: other.viewBasket ?? viewBasket,
                basketTitle: other.basketTitle ?? basketTitle,
                checkout: other.checkout ?? checkout,
                addToBasket: other.addToBasket ?? addToBasket,
                orderHelp: other.orderHelp ?? orderHelp,
                newChat: other.newChat ?? newChat
            )
        }
    }

    /// The headline of the empty chat.
    public let welcomeTitle: String?
    public let welcomeSubtitle: String?
    /// The hint in the message box.
    public let placeholder: String?
    /// The line under the retailer's name in the header.
    public let tagline: String?
    public let labels: Labels?

    public init(
        welcomeTitle: String? = nil,
        welcomeSubtitle: String? = nil,
        placeholder: String? = nil,
        tagline: String? = nil,
        labels: Labels? = nil
    ) {
        self.welcomeTitle = welcomeTitle
        self.welcomeSubtitle = welcomeSubtitle
        self.placeholder = placeholder
        self.tagline = tagline
        self.labels = labels
    }

    /// The names of the fields, as the `text` message spells them. `labels` is the last.
    static let keys = ["welcomeTitle", "welcomeSubtitle", "placeholder", "tagline", "labels"]

    /// The strings that are set, in the order of `keys`, without the labels.
    var pairs: [(String, String)] {
        zip(Self.keys, [welcomeTitle, welcomeSubtitle, placeholder, tagline])
            .compactMap { key, value in value.map { (key, $0) } }
    }

    /// This text with every field `other` sets replaced, the labels one by one.
    func merging(_ other: HephonText) -> HephonText {
        let merged = other.labels.map { (labels ?? Labels()).merging($0) } ?? labels
        return HephonText(
            welcomeTitle: other.welcomeTitle ?? welcomeTitle,
            welcomeSubtitle: other.welcomeSubtitle ?? welcomeSubtitle,
            placeholder: other.placeholder ?? placeholder,
            tagline: other.tagline ?? tagline,
            labels: merged
        )
    }
}

/// One override as it is sent: a word (a choice or a color) or a flag.
enum OverrideValue: Sendable, Equatable {
    case text(String)
    case flag(Bool)

    /// How the chat URL spells it: a flag is `true` or `false`.
    var query: String {
        switch self {
        case let .text(text): text
        case let .flag(flag): flag ? "true" : "false"
        }
    }
}

/// A key of an `appearance` or `text` message's data, by its name.
struct OverrideKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) {
        stringValue = name
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

extension HephonAppearance {
    /// Only the fields that are set, a flag as a JSON boolean.
    func encodeData(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: OverrideKey.self)
        for (key, value) in pairs {
            switch value {
            case let .text(text): try container.encode(text, forKey: OverrideKey(key))
            case let .flag(flag): try container.encode(flag, forKey: OverrideKey(key))
            }
        }
    }
}

extension HephonText {
    /// Only the fields that are set; `labels` is left out when no label is.
    func encodeData(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: OverrideKey.self)
        for (key, value) in pairs {
            try container.encode(value, forKey: OverrideKey(key))
        }
        let set = labels?.pairs ?? []
        if !set.isEmpty {
            var nested = container.nestedContainer(keyedBy: OverrideKey.self, forKey: OverrideKey("labels"))
            for (key, value) in set {
                try nested.encode(value, forKey: OverrideKey(key))
            }
        }
    }
}
