import Foundation

/// What the chat's web view does with a navigation.
public enum HephonNavigation: String, Sendable {
    /// The chat page: load it in the web view.
    case allow
    /// Anything else the shopper tapped: open it in the browser or the app it belongs to
    /// (tel:, mailto:, a retailer page, the chat's privacy page).
    case openExternally
    /// A frame or script trying to load something other than a web, tel: or mailto: link.
    case block

    /// The web view shows only the chat: `chatPath` (`/c/<organization>`) and the paths under
    /// it, in the main frame, on `allowedOrigins` (the Hephon host and any custom domain).
    /// That keeps the chat in place when the shopper taps one of its own links: every other
    /// page of those origins (the chat footer's `/legal/privacy`) opens outside the app.
    ///
    /// A web link opens outside the app even when `isMainFrame` is false: WebKit reports a
    /// `target="_blank"` link (how the chat renders the agent's links) as a navigation with no
    /// target frame. The chat loads no frames of its own, so such a request is a tap.
    public static func decide(
        _ url: URL,
        isMainFrame: Bool,
        allowedOrigins: Set<String>,
        chatPath: String
    ) -> HephonNavigation {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" {
            return .allow
        }
        if isMainFrame,
           let origin = origin(of: url),
           allowedOrigins.contains(origin),
           isUnder(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "", chatPath)
        {
            return .allow
        }
        if linkSchemes.contains(scheme) {
            return .openExternally
        }
        if !isMainFrame || scheme == "javascript" || scheme == "data" {
            return .block
        }
        return .openExternally
    }

    /// `scheme://host[:port]`, lowercased, without the default port, or nil for anything but
    /// an http(s) URL with a host. The same rule as the page's `originOf`.
    public static func origin(of url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return origin(scheme: parts.scheme ?? "", host: parts.host ?? "", port: parts.port ?? 0)
    }

    /// The origin of a `WKSecurityOrigin`'s parts, where WebKit reports port 0 for the
    /// scheme's default port.
    public static func origin(scheme: String, host: String, port: Int) -> String? {
        let scheme = scheme.lowercased()
        guard !host.isEmpty, scheme == "https" || scheme == "http" else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let suffix = port == 0 || port == defaultPort ? "" : ":\(port)"
        return "\(scheme)://\(host.lowercased())\(suffix)"
    }

    /// `url` for a load after the first one: without the launch token or code it came with (each
    /// works once, and the page keeps its session), and in `store` when it names none, because
    /// the page keeps its session per store. `launchToken` is a fresh token to launch with instead.
    static func relaunchURL(_ url: URL, store: String = "", launchToken: String? = nil) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var query = (parts.percentEncodedQuery ?? "").split(separator: "&").map(String.init)
            .filter { !["lt", "code"].contains(name(of: $0)) }
        if let launchToken {
            query.insert("lt=\(queryValue(launchToken))", at: 0)
        } else if !store.isEmpty, !query.contains(where: { name(of: $0) == "store" }) {
            query.append("store=\(queryValue(store))")
        }
        parts.percentEncodedQuery = query.isEmpty ? nil : query.joined(separator: "&")
        parts.fragment = nil
        return parts.url ?? url
    }

    private static func name(of pair: String) -> Substring {
        pair.prefix { $0 != "=" }
    }

    /// Links a shopper can tap that open outside the app from any frame.
    private static let linkSchemes: Set<String> = ["https", "http", "tel", "mailto"]

    /// `path` is `base` or a path below it, ignoring a trailing slash.
    private static func isUnder(_ path: String, _ base: String) -> Bool {
        var root = Substring(base)
        while root.hasSuffix("/") {
            root = root.dropLast()
        }
        return path == root || path.hasPrefix("\(root)/")
    }
}

/// RFC 3986's unreserved characters, the only ones a query value keeps as they are.
private let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

/// `value` with everything but the unreserved characters percent-encoded (`+` and `/` too).
func queryValue(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}
