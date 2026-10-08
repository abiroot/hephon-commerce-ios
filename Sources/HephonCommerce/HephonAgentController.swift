import Combine
import Foundation
import os
import WebKit

/// How the chat opens for one shopper: a launch token your server signs, or a code from
/// `POST /v1/sessions`. Either works once. Pass nil for an anonymous chat in `store`
/// (refused when the retailer requires a launch token).
public enum HephonLaunch: Sendable, Equatable {
    case token(String)
    case code(String)
}

/// Where the chat page is in loading.
public enum HephonPageState: Sendable, Equatable {
    /// The page is loading.
    case loading
    /// The page loaded. The bridge may still be getting ready.
    case loaded
    /// The page could not be loaded (offline, DNS, TLS). Call `reload()`.
    case failed
}

/// Runs one Hephon chat in a web view and turns its bridge messages into typed callbacks.
///
/// Make a new controller every time the chat opens: a launch token or code is good for one
/// open. Show it with `HephonAgentViewController` (UIKit) or `HephonAgentView` (SwiftUI);
/// dismissing either disposes the controller. Callbacks that use the controller capture it
/// weakly: `controller.onReady = { [weak controller] _ in controller?.sendCartSnapshot([]) }`.
@MainActor
public final class HephonAgentController: ObservableObject {
    /// Hephon's production host.
    public nonisolated static let defaultHost = URL(string: "https://commerce.hephon.ai")!

    /// The chat page URL this controller opens.
    public let url: URL

    /// Origins the web view may show: the host and the custom domains.
    public let allowedOrigins: Set<String>

    /// Loading, loaded or failed: what `HephonAgentViewController` shows over the page.
    @Published public private(set) var pageState: HephonPageState = .loading

    /// Lets Safari's Web Inspector attach (iOS 16.4+). On in debug builds. Set it before the
    /// view appears.
    public var isInspectable: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    /// The chat said `ready`.
    public var onReady: (@MainActor (HephonReady) -> Void)?
    /// A line was added to the basket (by the agent, the shopper or you).
    public var onItemAdded: (@MainActor (CartItemEvent) -> Void)?
    /// A line's quantity changed.
    public var onItemUpdated: (@MainActor (CartItemEvent) -> Void)?
    /// A line was removed.
    public var onItemRemoved: (@MainActor (CartItemEvent) -> Void)?
    /// The basket was emptied.
    public var onCartCleared: (@MainActor (CartCleared) -> Void)?
    /// The shopper tapped checkout: open your checkout with this cart.
    public var onCheckout: (@MainActor (CartHandoff) -> Void)?
    /// The agent handed the conversation to a person.
    public var onHandoff: (@MainActor (HephonHandoff) -> Void)?
    /// The shopper opened a product.
    public var onOpenProduct: (@MainActor (OpenProduct) -> Void)?
    /// The chat session ended (expired or revoked). Return a fresh launch token from your
    /// server to continue in place, or nil (or throw) to leave the chat showing its notice.
    ///
    /// When the chat refuses the tokens you return (a wrong key id, audience or store, a
    /// reused token), it reports the session expired again. The controller then asks again
    /// after 2 s and 4 s, and after three refused tokens in a row it stops asking.
    public var onSessionExpired: (@MainActor () async throws -> String?)?
    /// The chat asked to close (web widget only today).
    public var onClose: (@MainActor () -> Void)?
    /// The page wants the microphone for voice. Ask iOS (`NSMicrophoneUsageDescription` in
    /// Info.plist) and return whether it was granted. Without it, or when it throws, the
    /// microphone is refused and the chat stays text only.
    public var onMicrophonePermission: (@MainActor () async throws -> Bool)?

    /// Message ids remembered for deduplication.
    static let seenLimit = 500
    /// Tokens in a row the chat may refuse before the controller stops asking.
    static let maxRenewals = 3
    /// A renewed session that lasts this long was accepted: the chat answers a refused token
    /// within a few seconds.
    static let renewalSettles: TimeInterval = 30

    /// Waits between renewals; tests replace it.
    var sleep: @MainActor (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    /// The clock renewals settle by; tests replace it.
    var now: @MainActor () -> Date = { Date() }

    private var driver: (any WebViewDriving)?
    private var bridgeReady = false
    private var disposed = false
    private var outbox: [HostMessage] = []
    private var delivery: Task<Void, Never>?
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private var renewal: Task<Void, Never>?
    private var renewals = 0
    private var lastRenewal: Date?
    /// `/c/<organization>` on the host: the only page the web view keeps.
    private let chatPath: String

    static let log = Logger(subsystem: "ai.hephon.commerce", category: "HephonCommerce")

    /// Opens `<host>/c/<organization>` for one shopper.
    ///
    /// The web view only shows the chat (`/c/<organization>`) on `host` and `customDomains`;
    /// every other link, the chat's own privacy page included, opens outside the app.
    public init(
        host: URL = HephonAgentController.defaultHost,
        organization: String,
        launch: HephonLaunch? = nil,
        store: String? = nil,
        locale: String? = nil,
        customDomains: [URL] = []
    ) {
        let url = Self.chatURL(
            host: host, organization: organization, launch: launch, store: store, locale: locale
        )
        self.url = url
        chatPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        allowedOrigins = Set(([host] + customDomains).compactMap(HephonNavigation.origin(of:)))
    }

    /// `<host>/c/<organization>?…&embed=ios&sdk=<version>`. A store only goes with an anonymous
    /// launch: a token or code already names it.
    public nonisolated static func chatURL(
        host: URL,
        organization: String,
        launch: HephonLaunch? = nil,
        store: String? = nil,
        locale: String? = nil,
        embed: String = "ios",
        sdk: String = HephonCommerceSDK.version
    ) -> URL {
        var parts = URLComponents(url: host, resolvingAgainstBaseURL: false) ?? URLComponents()
        var base = Substring(parts.percentEncodedPath)
        while base.hasSuffix("/") {
            base = base.dropLast()
        }
        parts.percentEncodedPath = "\(base)/c/\(encode(organization))"
        let query: [(String, String?)] = switch launch {
        case let .token(token): [("lt", token)]
        case let .code(code): [("code", code)]
        case nil: [("store", store)]
        }
        parts.percentEncodedQuery = (query + [("embed", embed), ("sdk", sdk), ("locale", locale)])
            .compactMap { key, value in value.map { "\(key)=\(encode($0))" } }
            .joined(separator: "&")
        parts.fragment = nil
        // A URL built from a URL's own parts and percent-encoded values always parses.
        return parts.url!
    }

    /// Sends your cart so the chat basket matches it.
    public func sendCartSnapshot(_ items: [CartSnapshotItem]) {
        send(.cartSnapshot(items))
    }

    /// Tells the chat your app's color scheme.
    public func setTheme(_ scheme: HephonScheme) {
        send(.theme(scheme))
    }

    /// Puts the cursor in the chat's message box.
    public func focus() {
        send(.focus())
    }

    /// Delivers `message` to the page, or holds it until the page is ready.
    public func send(_ message: HostMessage) {
        if disposed {
            return
        }
        if !bridgeReady {
            outbox.append(message)
            return
        }
        deliver(message)
    }

    /// Loads the chat again, after `.failed`: where the chat was (a view inside it), unless
    /// the web view is somewhere else.
    public func reload() {
        guard !disposed, let driver else {
            return
        }
        pageState = .loading
        let again = driver.url.flatMap { current in
            HephonNavigation.origin(of: current) != nil
                && decide(current, isMainFrame: true) == .allow ? current : nil
        }
        driver.load(again ?? url)
    }

    /// Unloads the chat and stops callbacks. The page is unloaded at once, so a live call or a
    /// spoken reply stops with it. Dismissing the view does this for you.
    public func dispose() {
        if disposed {
            return
        }
        disposed = true
        renewal?.cancel()
        outbox.removeAll()
        driver?.detach()
        driver?.load(URL(string: "about:blank")!)
    }

    // MARK: - The web view's side (WebKitHost, and the tests' fake)

    /// The web view showing this chat, made and loaded on first use.
    func webView() -> WKWebView {
        if let host = driver as? WebKitHost {
            return host.webView
        }
        let host = WebKitHost(controller: self)
        attach(host)
        return host.webView
    }

    /// Takes the web view and loads the chat. The driver adds the bridge before this.
    func attach(_ driver: any WebViewDriving) {
        self.driver = driver
        if !disposed {
            driver.load(url)
        }
    }

    /// One bridge message from the page: only the chat's main frame on an allowed origin
    /// counts. Then parsed, deduplicated and dispatched.
    func receive(_ json: String, isMainFrame: Bool, origin: String?) {
        guard !disposed, isMainFrame, let origin, allowedOrigins.contains(origin) else {
            return
        }
        guard let envelope = PageMessage.parse(json) else {
            Self.log.debug("Ignored a message that is not bridge v1: \(json, privacy: .private)")
            return
        }
        guard seen.insert(envelope.id).inserted else {
            return
        }
        seenOrder.append(envelope.id)
        if seenOrder.count > Self.seenLimit {
            seen.remove(seenOrder.removeFirst())
        }

        switch envelope.message {
        case let .ready(ready):
            bridgeReady = true
            pageState = .loaded
            let pending = outbox
            outbox.removeAll()
            pending.forEach(deliver)
            onReady?(ready)
        case let .cartItem(change, event):
            switch change {
            case .added: onItemAdded?(event)
            case .updated: onItemUpdated?(event)
            case .removed: onItemRemoved?(event)
            }
        case let .cartCleared(cleared): onCartCleared?(cleared)
        case let .checkout(cart): onCheckout?(cart)
        case let .handoff(handoff): onHandoff?(handoff)
        case let .openProduct(product): onOpenProduct?(product)
        case .sessionExpired: renewSession()
        case .close: onClose?()
        case .resize: break
        }
    }

    /// Whether the web view loads `url`; anything that opens outside the app is opened here.
    func navigate(to url: URL, isMainFrame: Bool) -> Bool {
        let decision = decide(url, isMainFrame: isMainFrame)
        if decision == .openExternally, !disposed {
            driver?.openExternally(url)
        }
        return decision == .allow
    }

    /// A new document has a new bridge: hold messages until it says ready.
    func didStartLoading() {
        guard !disposed else {
            return
        }
        bridgeReady = false
        pageState = .loading
    }

    func didFinishLoading() {
        if !disposed, pageState == .loading {
            pageState = .loaded
        }
    }

    /// Only the chat failing counts: a refused external link or a replaced load also fails.
    func didFailLoading(_ error: any Error) {
        let error = error as NSError
        let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        let ours = failing.map { allowedOrigins.contains(HephonNavigation.origin(of: $0) ?? "") } ?? true
        if !disposed, ours, !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) {
            pageState = .failed
        }
    }

    /// Grants the microphone only for a microphone-only request from an allowed origin, and
    /// only when the app's `onMicrophonePermission` says the shopper allowed it.
    func allowsMicrophone(origin: String?, microphoneOnly: Bool) async -> Bool {
        guard !disposed, microphoneOnly, let origin, allowedOrigins.contains(origin),
              let ask = onMicrophonePermission
        else {
            return false
        }
        do {
            return try await ask()
        } catch {
            Self.log.error("onMicrophonePermission threw: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private

    private func decide(_ url: URL, isMainFrame: Bool) -> HephonNavigation {
        HephonNavigation.decide(
            url,
            isMainFrame: isMainFrame,
            allowedOrigins: allowedOrigins,
            chatPath: chatPath
        )
    }

    /// In order, and only to the chat: a page the web view strayed to never gets host messages.
    private func deliver(_ message: HostMessage) {
        let previous = delivery
        delivery = Task { [weak self] in
            await previous?.value
            guard let self, !disposed, let driver,
                  let current = driver.url.flatMap(HephonNavigation.origin(of:)),
                  allowedOrigins.contains(current)
            else {
                return
            }
            do {
                try await driver.deliver(message.json())
            } catch {
                Self.log.error("Could not deliver \(message.type): \(error.localizedDescription)")
            }
        }
    }

    /// One renewal at a time; a token the chat refuses (it expires again within
    /// `renewalSettles`) counts towards `maxRenewals`, with 2 s and 4 s between asks.
    private func renewSession() {
        guard let renew = onSessionExpired, renewal == nil else {
            return
        }
        if let last = lastRenewal, now().timeIntervalSince(last) >= Self.renewalSettles {
            renewals = 0
        }
        let attempt = renewals
        guard attempt < Self.maxRenewals else {
            // For good: a later expiry is the shopper writing again, not a token accepted.
            lastRenewal = nil
            Self.log.error(
                "The chat refused \(attempt) launch tokens in a row; not asking for another. Check the key id, audience and store."
            )
            return
        }
        renewal = Task { [weak self] in
            defer { self?.renewal = nil }
            if attempt > 0 {
                await self?.sleep(TimeInterval(1 << attempt))
            }
            guard let self, !disposed, !Task.isCancelled else {
                return
            }
            let token: String?
            do {
                token = try await renew()
            } catch {
                // Offline, or your server failed: same as nil. The chat reports the session
                // expired again when the shopper next writes, and the controller asks then.
                Self.log.error("onSessionExpired threw: \(error.localizedDescription)")
                return
            }
            guard !disposed, let token, !token.isEmpty else {
                return
            }
            renewals = attempt + 1
            lastRenewal = now()
            send(.sessionLaunch(token))
        }
    }
}

/// One chat per controller: `.sheet(item: $assistant) { HephonAgentView(controller: $0) }`.
extension HephonAgentController: Identifiable {}

/// The web view as the controller drives it: `WebKitHost` in apps, a fake in tests.
@MainActor
protocol WebViewDriving: AnyObject {
    /// The page the web view shows now.
    var url: URL? { get }
    func load(_ url: URL)
    /// Calls `window.hephon.receive(json)` in the page.
    func deliver(_ json: String) async throws
    /// Hands a link to iOS (Safari, Phone, Mail, another app).
    func openExternally(_ url: URL)
    /// Removes the bridge: nothing from the page reaches the controller any more.
    func detach()
}

/// RFC 3986's unreserved characters, the only ones a query value keeps as they are.
private let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

/// `value` with everything but the unreserved characters percent-encoded (`+` and `/` too).
private func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}
