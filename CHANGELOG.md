## 1.1.0

- `preload()`: loads the chat ahead of the tap, in a web view that is in no window. Keep
  one controller for a shopper and a store and call `preload()` in `viewDidAppear` of
  your store screen; the assistant then opens at once.
- A controller that was preloaded stays loaded between opens: dismissing
  `HephonAgentViewController` or `HephonAgentView` hides the chat instead of disposing
  the controller. Call `dispose()` on logout. A controller that was never preloaded
  behaves as in 1.0.0: it loads when shown and is disposed on dismiss.
- A hidden chat is released after 10 minutes and on a memory warning, and loads again
  on the next `preload()` or open. When iOS ends its web process while it is hidden, it
  loads again then too, without a retry screen.
- `onTiming`: `HephonOpenTiming(open:preloaded:)` each time the chat is shown, with
  the milliseconds from the view appearing to a usable chat.
- The loading indicator hides when the chat is first drawn, not when the page has
  finished loading.
- A reload never replays a spent launch token or code. With a token or code,
  `onSessionExpired` is now also asked for a fresh token when the chat loads again in
  a new web view or after its web process ended, so set it before `preload()`.
- A load that needs a fresh token waits 15 seconds for `onSessionExpired`, then loads
  without the shopper instead of staying on the loading indicator.
- A kept chat inside a container of your own (a wrapper view controller, a tab bar or
  navigation controller) is hidden when that container is dismissed or removed.
- `HostMessage` has `.visibility`. `PageMessage` is unchanged, so a `switch` over it
  written for 1.0.0 still compiles: code written for 1.0.0 needs no change.

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
