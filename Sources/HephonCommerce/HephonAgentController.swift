import Combine
import Foundation
import os
import UIKit
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
/// Keep one controller for a shopper and a store, call `preload()` when your store screen
/// appears, and show it with `HephonAgentViewController` (UIKit) or `HephonAgentView`
/// (SwiftUI) as often as you like: the chat is loaded before the tap and stays loaded between
/// opens. Call `dispose()` on logout.
///
/// A controller that was never preloaded works as in 1.0.0: it loads when it is shown and
/// dismissing the view disposes it. Callbacks that use the controller capture it weakly:
/// `controller.onReady = { [weak controller] _ in controller?.sendCartSnapshot([]) }`.
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
    /// Required with `preload()` when the chat opens with a launch token or code: it is also
    /// asked each time the chat is loaded again (after it was released, or its web process
    /// ended), because the first token works once.
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
    /// How long the chat took to open, each time it is shown.
    public var onTiming: (@MainActor (HephonOpenTiming) -> Void)?

    /// Message ids remembered for deduplication.
    static let seenLimit = 500
    /// Tokens in a row the chat may refuse before the controller stops asking.
    static let maxRenewals = 3
    /// A renewed session that lasts this long was accepted: the chat answers a refused token
    /// within a few seconds.
    static let renewalSettles: TimeInterval = 30
    /// In `ready`: the page can be told it is hidden, so it can stay loaded there.
    static let visibility = "visibility"
    /// How long a load waits for `onSessionExpired` before it goes on without a token.
    static let tokenWait: TimeInterval = 15
    /// What a web view shows once its chat is unloaded.
    static let blank = URL(string: "about:blank")!

    /// A hidden chat is released after this long.
    var idleRelease: TimeInterval = 600
    /// Makes the web view; tests replace it.
    var makeDriver: @MainActor (HephonAgentController) -> any WebViewDriving = { WebKitHost(controller: $0) }
    var warn: @MainActor (String) -> Void = { message in HephonAgentController.log.warning("\(message, privacy: .public)") }
    /// Waits between renewals and before an idle release; tests replace it.
    var sleep: @MainActor (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    /// The clock renewals settle by; tests replace it.
    var now: @MainActor () -> Date = { Date() }

    /// The web view. Nil before the first load and while a kept chat is released.
    private var driver: (any WebViewDriving)?
    private var bridgeReady = false
    private var disposed = false
    private var outbox: [HostMessage] = []
    private var delivery: Task<Void, Never>?
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    /// The request for a fresh launch token that is on its way.
    private var renewal: Task<String?, Never>?
    private var renewals = 0
    private var lastRenewal: Date?
    /// Opened with a launch token or code: a load in a new web view needs a fresh token.
    private let identified: Bool
    /// The chat URL was handed to a web view, so its token or code may be spent.
    private var launched = false
    /// The last `ready`: its store, and what the page can do.
    private var ready: HephonReady?
    /// The page in the web view said ready, so its session is in that web view.
    private var hasSession = false
    /// Counts the pages lost with their web view or its process.
    private var pagesLost = 0
    /// `preload()` was called: dismissing the view hides the chat instead of ending it.
    private(set) var kept = false
    /// The view showing the chat.
    private weak var presenter: AnyObject?
    private var shown = false
    private var wasShown = false
    /// When the current show began, until the page has been told.
    private var shownAt: Date?
    /// The load that waits for a fresh launch token.
    private var loading: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var memoryWarnings: AnyCancellable?
    private var warned = false
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
        identified = launch != nil
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
        parts.percentEncodedPath = "\(base)/c/\(queryValue(organization))"
        let query: [(String, String?)] = switch launch {
        case let .token(token): [("lt", token)]
        case let .code(code): [("code", code)]
        case nil: [("store", store)]
        }
        parts.percentEncodedQuery = (query + [("embed", embed), ("sdk", sdk), ("locale", locale)])
            .compactMap { key, value in value.map { "\(key)=\(queryValue($0))" } }
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

    /// Puts the cursor in the chat's message box. Call it after showing: a hidden chat ignores it.
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

    /// Makes sure the chat is loaded, without showing it, so the next open is immediate. From
    /// then on dismissing the view hides the chat instead of ending it.
    ///
    /// Call it where the assistant is likely to be opened (`viewDidAppear` of your store screen,
    /// not app start), each time that screen appears: a hidden chat is released after 10 minutes
    /// and on a memory warning, and nothing loads it again by itself. It does nothing while the
    /// chat is loaded and it never throws.
    ///
    /// With a launch token or code, set `onSessionExpired` first: loading again needs a fresh
    /// token, so your token endpoint is called on every load after the first.
    public func preload() {
        guard !disposed else {
            return
        }
        if !kept {
            kept = true
            memoryWarnings = NotificationCenter.default
                .publisher(for: UIApplication.didReceiveMemoryWarningNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.release() }
        }
        if identified, onSessionExpired == nil {
            warnNoToken()
        }
        guard !shown else {
            return
        }
        ensureLoaded()
        armIdle()
    }

    /// Loads the chat again, after `.failed`: where the chat was (a view inside it), unless
    /// the web view is somewhere else. A launch token or code is never sent twice: once the
    /// chat was ready it loads without it, and when the page's session is gone (its web process
    /// ended, or the first load failed) `onSessionExpired` is asked for a fresh token first.
    public func reload() {
        guard !disposed, let driver else {
            return
        }
        let again = driver.url.flatMap { current in
            HephonNavigation.origin(of: current) != nil
                && decide(current, isMainFrame: true) == .allow ? current : nil
        }
        load(again ?? url)
    }

    /// Unloads the chat and stops callbacks, for good: call it on logout. The page is unloaded
    /// at once, so a live call or a spoken reply stops with it. Dismissing the view does this
    /// for you unless `preload()` was called.
    public func dispose() {
        if disposed {
            return
        }
        disposed = true
        renewal?.cancel()
        memoryWarnings = nil
        outbox.removeAll()
        unload()
    }

    // MARK: - The view's side (HephonAgentViewController, and the tests)

    /// `view` began to show the chat at `at`: load it if it is not, and tell the page.
    func viewShown(by view: AnyObject, at: Date) {
        guard !disposed else {
            return
        }
        presenter = view
        guard !shown else {
            return
        }
        shown = true
        wasShown = true
        shownAt = at
        idle?.cancel()
        ensureLoaded()
        sendVisibility()
    }

    /// `view` stopped showing the chat. A kept chat is hidden and stays loaded; any other is
    /// over, as in 1.0.0.
    func viewDismissed(by view: AnyObject) {
        guard kept else {
            dispose()
            return
        }
        guard !disposed, shown, presenter === view else {
            return
        }
        shown = false
        shownAt = nil
        // A page that cannot be told it is hidden would keep a call running, and a chat that
        // failed should load again on the next open.
        if !keepsWarm || pageState == .failed {
            release()
        } else {
            sendVisibility()
            armIdle()
        }
    }

    // MARK: - The web view's side (WebKitHost, and the tests' fake)

    /// The web view showing this chat. The view asks after `viewShown`, which made it; asked
    /// before anything loaded the chat, it is made and loaded here.
    func webView() -> WKWebView {
        let host = driver as? WebKitHost ?? WebKitHost(controller: self)
        if driver !== host {
            attach(host)
        }
        return host.webView
    }

    /// Takes the web view and loads the chat. The driver adds the bridge before this.
    func attach(_ driver: any WebViewDriving) {
        self.driver = driver
        if !disposed {
            load(url)
        }
    }

    /// One bridge message from the page: only the chat's main frame on an allowed origin
    /// counts. Then parsed, deduplicated and dispatched.
    func receive(_ json: String, isMainFrame: Bool, origin: String?) {
        guard !disposed, isMainFrame, let origin, allowedOrigins.contains(origin) else {
            return
        }
        guard let envelope = PageEvent.parse(json) else {
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

        switch envelope.event {
        // The chat is drawn before it is ready: the spinner can go.
        case .painted:
            if pageState == .loading {
                pageState = .loaded
            }
        case let .timing(timing): onTiming?(timing)
        case let .message(message): handle(message)
        }
    }

    private func handle(_ message: PageMessage) {
        switch message {
        case let .ready(ready):
            self.ready = ready
            hasSession = true
            // Dismissed before this page could say that it cannot be told it is hidden.
            if wasShown, !shown, !keepsWarm {
                release()
                return
            }
            bridgeReady = true
            pageState = .loaded
            // Every new document starts hidden: tell it again.
            sendVisibility()
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
        guard !disposed, driver != nil else {
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
        guard !disposed, ours, !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else {
            return
        }
        // Nobody is looking at a hidden chat that is kept: it loads again on the next show or preload.
        if kept, !shown {
            release()
        } else {
            pageState = .failed
        }
    }

    /// iOS ended the page's process (memory pressure). On screen, the chat loads again behind
    /// the spinner. A kept chat nobody is looking at waits for the next show or `preload()`:
    /// loaded at once it would be reclaimed again.
    func didTerminate() {
        guard !disposed, driver != nil else {
            return
        }
        if kept, !shown {
            release(unload: false)
        } else {
            lostPage()
            reload()
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

    /// A load the controller starts. The first one uses the chat URL as it is. Later ones never
    /// replay its token or code: when the page's session is gone, a chat opened with one asks
    /// `onSessionExpired` for a fresh token first. Loading without one and launching afterwards
    /// would show an anonymous chat in between.
    private func load(_ base: URL) {
        loading?.cancel()
        loading = nil
        pageState = .loading
        guard launched else {
            launched = true
            driver?.load(base)
            return
        }
        // The first token or code is spent once the page said ready.
        let plain = ready.map { HephonNavigation.relaunchURL(base, store: $0.storeId) } ?? base
        guard identified, !hasSession else {
            driver?.load(plain)
            return
        }
        guard onSessionExpired != nil else {
            warnNoToken()
            driver?.load(plain)
            return
        }
        let request = tokenRequest(expired: false)
        let sleep = sleep
        loading = Task { [weak self] in
            let token = await Self.token(from: request, within: Self.tokenWait, sleep)
            guard let self, !disposed, !Task.isCancelled else {
                return
            }
            loading = nil
            if token == nil {
                warnNoToken()
            }
            driver?.load(token.map { HephonNavigation.relaunchURL(self.url, launchToken: $0) } ?? plain)
        }
    }

    private func ensureLoaded() {
        if driver == nil {
            attach(makeDriver(self))
        } else if driver?.url == nil, loading == nil {
            // Blank: iOS ended the page's process while nobody looked.
            lostPage()
            load(url)
        }
    }

    /// Gives the web view back while the chat is hidden: the page is unloaded (which stops
    /// audio and the microphone) and the next show or `preload()` loads it again.
    private func release(unload: Bool = true) {
        guard !disposed, !shown, driver != nil else {
            return
        }
        self.unload(blank: unload)
        driver = nil
        lostPage()
        pageState = .loading
    }

    /// Stops what the controller has running for the web view and cuts the page off: no more
    /// messages from it, and with `blank` the page itself is unloaded.
    private func unload(blank: Bool = true) {
        idle?.cancel()
        loading?.cancel()
        loading = nil
        driver?.detach()
        if blank {
            driver?.load(Self.blank)
        }
    }

    /// The page and its session went with the web view or its process: hold messages for the
    /// next one, which starts a new count of refused tokens.
    private func lostPage() {
        pagesLost += 1
        bridgeReady = false
        hasSession = false
        renewals = 0
        lastRenewal = nil
    }

    private func armIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            guard let wait = self?.idleRelease, let sleep = self?.sleep else {
                return
            }
            await sleep(wait)
            if !Task.isCancelled {
                self?.release()
            }
        }
    }

    /// Whether the page can be told it is hidden, so it can stay loaded there. A page that has
    /// not said ready yet is given the benefit of the doubt.
    private var keepsWarm: Bool {
        ready?.capabilities.contains(Self.visibility) ?? true
    }

    /// Tells the page whether it is on screen, once it listens. Before its first show a page
    /// counts as hidden by itself.
    private func sendVisibility() {
        guard bridgeReady, wasShown else {
            return
        }
        deliver(.visibility(shown, at: shownAt))
        shownAt = nil
    }

    private func warnNoToken() {
        guard !warned else {
            return
        }
        warned = true
        warn(
            "This chat opens with a launch token or code, and onSessionExpired gives no fresh one: when the chat has to load again, it loads without the shopper. Set onSessionExpired before preload()."
        )
    }

    /// In order, and only to the chat: a page the web view strayed to never gets host messages,
    /// and neither does the next web view.
    private func deliver(_ message: HostMessage) {
        let previous = delivery
        let target = driver
        delivery = Task { [weak self] in
            await previous?.value
            guard let self, !disposed, let driver, driver === target,
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

    /// The session ended in the page: launch it again in place.
    private func renewSession() {
        guard onSessionExpired != nil, renewal == nil else {
            return
        }
        let request = tokenRequest(expired: true)
        let asking = pagesLost
        Task { [weak self] in
            // For the page that asked: one loaded since (in a new web view, or in this one after
            // its process ended) launched with this token in its URL, and a token works once.
            guard let token = await request.value, let self, pagesLost == asking else {
                return
            }
            send(.sessionLaunch(token))
        }
    }

    /// The token `request` brings, or nil when it has not answered within `seconds`: a handler
    /// that never returns must not leave the chat on its loading indicator for good.
    private static func token(
        from request: Task<String?, Never>,
        within seconds: TimeInterval,
        _ sleep: @escaping @MainActor (TimeInterval) async -> Void
    ) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            var waiting = true
            let finish: @MainActor (String?) -> Void = { token in
                if waiting {
                    waiting = false
                    done.resume(returning: token)
                }
            }
            Task { await finish(request.value) }
            Task {
                await sleep(seconds)
                finish(nil)
            }
        }
    }

    /// A fresh launch token from `onSessionExpired`, one request at a time.
    private func tokenRequest(expired: Bool) -> Task<String?, Never> {
        if let renewal {
            return renewal
        }
        let request = Task { [weak self] () -> String? in
            defer { self?.renewal = nil }
            return await self?.askForToken(expired: expired)
        }
        renewal = request
        return request
    }

    /// `expired`: the page said its session ended. Only those asks count: a token the chat
    /// refuses (it expires again within `renewalSettles`) counts towards `maxRenewals`, with
    /// 2 s and 4 s between asks. Loading the chat again is not a refusal, however often.
    private func askForToken(expired: Bool) async -> String? {
        guard let renew = onSessionExpired else {
            return nil
        }
        var attempt = 0
        let asking = pagesLost
        if expired {
            if let last = lastRenewal, now().timeIntervalSince(last) >= Self.renewalSettles {
                renewals = 0
            }
            attempt = renewals
            guard attempt < Self.maxRenewals else {
                // For good: a later expiry is the shopper writing again, not a token accepted.
                lastRenewal = nil
                Self.log.error(
                    "The chat refused \(attempt) launch tokens in a row; not asking for another. Check the key id, audience and store."
                )
                return nil
            }
            if attempt > 0 {
                await sleep(TimeInterval(1 << attempt))
            }
            guard !disposed, !Task.isCancelled else {
                return nil
            }
        }
        let token: String?
        do {
            token = try await renew()
        } catch {
            // Offline, or your server failed: same as nil. The chat reports the session
            // expired again when the shopper next writes, and the controller asks then.
            Self.log.error("onSessionExpired threw: \(error.localizedDescription)")
            return nil
        }
        guard !disposed, let token, !token.isEmpty else {
            return nil
        }
        // A token that ends up loading a new page was not refused by it.
        if expired, pagesLost == asking {
            renewals = attempt + 1
            lastRenewal = now()
        }
        return token
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
