## 2.0.0

Breaking:

- `itemId` is now the product's id in the store, which for a platform with a row per store
  is that row's id, not the catalog id. The catalog id is in the new `catalogId`. For a
  platform with one id per product nothing changes: both are the same.
- Key your cart on `itemId`: it is what a cart line or an order line in the session's
  store is keyed on, so it needs no lookup. Use `catalogId` for what is not about one
  store (your product page's route, analytics, matching your catalog).
- `CartItem.catalogId`, `CartHandoffItem.catalogId` and `OpenProduct.catalogId`: a
  `String`, always there, next to `itemId`. That is the item of `onItemAdded`,
  `onItemUpdated` and `onItemRemoved`, each removed line of `onCartCleared`, each line of
  `onCheckout`, and `onOpenProduct`. A message without it is ignored, like one without
  `itemId`. `substituteItemId` keeps its name: the substitute's id in the same store.
- A `cart.snapshot` line names its item by exactly one id. `CartSnapshotItem(itemId:quantity:)`
  is the normal case and compiles as before; `CartSnapshotItem(catalogId:quantity:)` is
  for a cart keyed on catalog ids. `CartSnapshotItem.itemId` and `.catalogId` are optional
  to read: the one the line was not made with is nil. An empty id now stops in `init`
  (`precondition`), like a negative quantity.

Added:

- `HephonAppearance`: 12 more optional overrides, 36 in all.
  - colors (`"#RRGGBB"`): `cardColor` (product cards, the basket, the product sheet and
    menus), `textColor` (replies, titles, prices), `mutedColor` (small print), `lineColor`
    (the outlines of cards, chips and the message box).
  - `fontFamily`: a typeface the device already has, like `"Avenir Next"`, ahead of
    `font`. 1 to 40 letters, digits, spaces, dots, dashes or underscores. A name that is
    not one stops a debug build (`assertionFailure`) and is dropped in a release build,
    like a bad color. `HephonAppearance.isFontFamily(_:)` checks one.
  - what is shown: `showBasketButton` (the basket button in the header), `showBasketBar`
    (the summary bar above the message box: an app with its own cart bar sets it false;
    `showBasket` still hides the whole basket), `showAssistantName` (the name above each
    reply), `showStarters` (the suggested first messages on the welcome screen).
  - what an app can only hide: `hideOrderHelp` ("Help with an order"), `hideVoice` (the
    microphone: voice messages and dictation) and `hideCall` (the live voice call). `true`
    hides the part; what the retailer has switched off stays off.
- `HephonText`: `assistantName` (the name in the header and above each reply, up to 40
  characters), and five more labels: `total`, `emptyBasket`, `thinking`, `typing`,
  `tryAgain`.

## 1.2.0

- `HephonAppearance`: your app can restyle the chat it opens. 24 optional overrides, and
  one you leave out keeps what the retailer set:
  - colors (`"#RRGGBB"`): `primaryColor`, `deepColor`, `accentColor`, `dealColor`,
    `ctaColor`, `headerColor`, `bubbleColor`, `surfaceColor`.
  - shape and type: `scheme` (`.light`, `.dark`, `.auto`), `corners` (`.round`, `.soft`,
    `.square`), `header` (`.plain`, `.brand`), `buttons` (`.pill`, `.rounded`, `.square`),
    `bubble` (`.brand`, `.soft`), `font` (`.geist`, `.manrope`, `.system`), `starterStyle`
    (`.photos`, `.list`).
  - what is shown (`true` or `false`): `showHeader`, `showLogo`, `showBasket`,
    `showCheckout`, `showNewChat`, `showFollowUps`, `showSteps`, `productSheet`,
    `addFromCards`.
- `HephonAgentController(appearance:)`: the chat is drawn restyled from its first paint.
  The overrides are part of the chat URL, so a reload and a chat that loads again after
  it was released keep them. `chatURL` takes `appearance:` too.
- `setAppearance(_:)`: restyles the open chat. Only the fields that are set change, over
  what your app sent before. Held until the chat is ready, like every message, and sent
  again when the chat loads again. `HostMessage` has `.appearance`.
- A color that is not `#RRGGBB` stops a debug build in `HephonAppearance.init`
  (`assertionFailure`). A release build drops that color and keeps the rest.
  `HephonAppearance.isColor(_:)` checks one.
- `HephonText`: your app can change the chat's words: `welcomeTitle`, `welcomeSubtitle`,
  `placeholder`, `tagline` and `labels` (`viewBasket`, `basketTitle`, `checkout`,
  `addToBasket`, `orderHelp`, `newChat`). Pass it as `HephonAgentController(text:)` or
  to `setText(_:)`, which changes only what is set, the labels one by one. Text is sent
  as a message once the chat is ready, never on the chat URL, and again each time the
  chat loads again. `HostMessage` has `.text`.
- The retailer can switch app changes off in Configure. The chat then ignores appearance
  and text, and its `ready` lists neither the `appearance` nor the `text` capability.
- `setTheme` and `HephonScheme` are unchanged: code written for 1.1.0 needs no change.

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
