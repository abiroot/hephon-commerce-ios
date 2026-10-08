## 1.0.0

- First release: `HephonAgentController`, `HephonAgentViewController` (UIKit, a
  full-height sheet with a grabber) and `HephonAgentView` (SwiftUI), on WKWebView.
  iOS 15 or later, Xcode 16 or later, Swift 6 strict concurrency.
- Installs with Swift Package Manager from
  `https://github.com/abiroot/hephon-commerce-ios.git`, Dependency Rule "Up to Next
  Major Version" from 1.0.0.
- Bridge envelope v1: typed callbacks for cart changes (added, updated, removed,
  cleared), checkout, handoff to a person, product opened, session renewal and close;
  cart snapshot, theme and focus from the app. Events are deduplicated by message id,
  and messages sent before the chat is ready are held until it is.
- Only the chat's main frame on the Hephon host or your custom domains can post to
  the app. The web view shows only the chat (`/c/<organization>`); other links, the
  chat's privacy page included, open outside the app.
- The microphone is granted to the chat only when `onMicrophonePermission` returns
  true; anything else, or a throw, denies it. Spoken replies play inline without a tap.
- `onSessionExpired` renews the session in place. A throw counts as nil; after three
  refused tokens in a row (asked again after 2 s and 4 s) the controller stops asking.
- The chat URL carries `sdk=1.0.0` (`HephonCommerceSDK.version`), so the retailer's
  Install screen shows which version your app runs and when an update is out.
