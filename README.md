# HephonCommerce for iOS

Put the Hephon Commerce shopping agent in your iOS app. The agent runs in a `WKWebView` on
the retailer's chat page; this package opens it for one shopper, keeps it on Hephon's
origin, and turns everything it does to the basket into typed callbacks in **your own item
ids**, so your app's cart and checkout stay in charge.

- `HephonAgentController`: one chat for one shopper (launch token or code, callbacks, cart
  snapshot, appearance, text, messages and suggestions, focus). An `ObservableObject` with `@Published pageState`. Call
  `preload()` and the chat is loaded before the shopper taps, and stays loaded between opens.
- `HephonAgentViewController`: the chat with loading and retry states. Presented, it is a
  full-height sheet with a grabber, or a full page with `presentation: .fullScreen`.
- `HephonAgentView`: the same for SwiftUI, for `.sheet` or a screen of its own.

iOS 15 or later, Xcode 16 or later. No dependencies.

## Install

**Xcode:** File > Add Package Dependencies, paste

```
https://github.com/abiroot/hephon-commerce-ios.git
```

set Dependency Rule to **Up to Next Major Version** from `2.2.0`, and add `HephonCommerce`
to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/abiroot/hephon-commerce-ios.git", from: "2.2.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "HephonCommerce", package: "hephon-commerce-ios"),
    ]),
]
```

The retailer's **Install** screen in Hephon shows the same steps with the latest version.

### Updates

- Xcode: File > Packages > Update to Latest Package Versions.
- Package.swift: `swift package update`.

Both stay within your major version. To cross one, read CHANGELOG.md (also on the Install
screen), then raise the rule's lower bound (`from: "2.2.0"`). The Install screen shows which
version your app runs and says when an update is out.

### Voice (optional)

Shoppers can talk to the agent and hear it reply. Without this the chat still works, by
text. Add to `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Talk to the shopping assistant with your voice.</string>
```

and answer the chat's microphone request with iOS's:

```swift
import AVFAudio

controller.onMicrophonePermission = {
    if #available(iOS 17, *) { return await AVAudioApplication.requestRecordPermission() }
    return await withCheckedContinuation { done in
        AVAudioSession.sharedInstance().requestRecordPermission { @Sendable granted in done.resume(returning: granted) }
    }
}
```

## Open the assistant

UIKit:

```swift
import HephonCommerce
import UIKit

func openAssistant(from presenter: UIViewController) async throws {
    // Your server signs a fresh launch token for every open (see below).
    let launchToken = try await api.hephonLaunchToken(store: "branch-7")
    let controller = HephonAgentController(
        organization: "your-retailer",
        launch: .token(launchToken),
        locale: "ar"
    )
    // Held until the chat is ready.
    controller.sendCartSnapshot(cart.snapshot())
    // Your own snapshot comes back with origin .host: skip it, it is your cart already.
    controller.onItemAdded = { event in
        if event.origin != .host { cart.set(event.item.itemId, event.item.quantity) }
    }
    controller.onItemUpdated = { event in
        if event.origin != .host { cart.set(event.item.itemId, event.item.quantity) }
    }
    controller.onItemRemoved = { event in
        if event.origin != .host { cart.remove(event.item.itemId) }
    }
    controller.onCartCleared = { _ in cart.clear() }
    controller.onCheckout = { handoff in openCheckout(handoff) }
    controller.onSessionExpired = { try await api.hephonLaunchToken(store: "branch-7") }
    presenter.present(HephonAgentViewController(controller: controller), animated: true)
}
```

SwiftUI:

```swift
@State private var assistant: HephonAgentController?

Button("Ask the assistant") { assistant = makeController() }
    .sheet(item: $assistant) { HephonAgentView(controller: $0) }
```

`HephonAgentController` is `Identifiable`, so `.sheet(item:)` opens a fresh chat each time
and clears `assistant` when the shopper closes it.

Opened this way, each open needs a **new controller**: a launch token or code works once,
and dismissing the sheet disposes the controller. That unloads the chat, so a live call or a
spoken reply stops with it. Callbacks that use the controller capture it `[weak controller]`.

## Preload and keep warm

Opening as above loads the chat after the tap. To open at once, keep one controller for
the shopper and the store, and load it before the tap:

```swift
final class StoreViewController: UIViewController {
    private let assistant: HephonAgentController

    init(launchToken: String) {
        assistant = HephonAgentController(organization: "your-retailer", launch: .token(launchToken))
        super.init(nibName: nil, bundle: nil)
        // Required with preload(): also asked each time the chat loads again.
        assistant.onSessionExpired = { try await api.hephonLaunchToken(store: "branch-7") }
        assistant.onItemAdded = { event in /* as above */ }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        assistant.preload()                 // each time the store screen appears
    }

    func openAssistant() {
        assistant.sendCartSnapshot(cart.snapshot())
        present(HephonAgentViewController(controller: assistant), animated: true)
    }
}
// On logout: assistant.dispose()
```

In SwiftUI, hold the controller in your model, call `preload()` in `.onAppear` and when
`scenePhase` becomes `.active`, and present it with
`.sheet(item: $shown) { HephonAgentView(controller: $0) }`, setting `shown` to the same
controller on every tap. `Example/` does exactly this.

- **`preload()` loads the chat in a web view that is in no window**, and from then on
  dismissing the view hides the chat instead of disposing the controller. The next open
  shows the same page: about 0.1 s on a simulator against a local server, where a chat
  made on the tap takes about 0.8 s.
- **Call it where the assistant is likely to be opened**, `viewDidAppear` of the store
  screen, not app start: each load costs a page render on Hephon and, with a launch token,
  a token from your server. Call it every time the screen appears and when your app comes
  back to the foreground. It does nothing while the chat is loaded, and nothing loads a
  released chat again by itself.
- **`onSessionExpired` is required with a launch token or code.** The first token works
  once, so your token endpoint is called for the preload and again each time the chat is
  loaded in a new web view. Without it the chat loads again without the shopper: anonymous
  where the retailer allows that, a notice to reopen from the app where it does not.
  The same happens when it has not answered after 15 seconds.
- **Dispose on logout**, and make a new controller for another shopper, store or locale:
  a loaded chat holds the previous shopper's session.
- **Send the cart before each show.** `onReady` runs when the chat loads, which is now
  before the shopper sees it, and `focus()` does nothing until the chat is on screen.
- **Memory**: a hidden chat is one loaded web page. It is released after 10 minutes and
  on a memory warning, and when iOS ends its web process while it is hidden it is loaded
  again on the next `preload()` or open, without a retry screen. An anonymous chat that
  was released starts fresh; a shopper with a launch token gets the conversation back.
- **A hidden chat is in no window.** That is the state this version ships, chosen on
  measurement (iPhone 17 simulator, iOS 26.2): the hidden load is ready before the tap,
  and a reply that is streaming when the sheet closes finishes while hidden and its cart
  events reach your app. On a device WebKit may suspend the web process of a web view
  that is in no window: such a reply can then stall until the chat is shown again and its
  cart events can arrive late. It is never stopped, the basket on Hephon's server has the
  items either way, and the signed webhook stays the source of truth.
- `onTiming` gives `HephonOpenTiming(open:preloaded:)` every time the chat is shown:
  `open` is the milliseconds from the view appearing to a usable chat (nil when the page
  could not confirm a frame), `preloaded` whether it was already loaded.

Retailers that cannot sign tokens open the session from their server with
`POST /api/v1/sessions` and pass the returned code with `.code(code)`. The code does not
carry the locale you sent, so pass `locale:` too. With neither, pass `store:` for an
anonymous chat (refused when the retailer requires launch tokens).

The chat opens on `https://commerce.hephon.ai` unless you pass `host:`. A retailer whose
chat also runs on its own domain passes that domain in `customDomains:`, so the web view
keeps it in place.

### Callbacks

All run on the main actor.

| Callback | When | You get |
|---|---|---|
| `onReady` | the chat is open and listening | store, resumed conversation, capabilities |
| `onItemAdded` / `onItemUpdated` / `onItemRemoved` | a basket line changed (by the agent, the shopper, or your snapshot) | `CartItemEvent`: `item.itemId`, `item.catalogId`, `quantity`, `previousQuantity`, `unitPrice`, `currency`, `title`, `imageUrl` (the main image, when the product has one; since 2.1.0), `origin` |
| `onCartCleared` | the basket was emptied | the removed lines, each with `itemId` and `catalogId` |
| `onCheckout` | the shopper tapped checkout | `CartHandoff` with every line in your ids (`itemId`, `catalogId`), total, currency, substitutions |
| `onHandoff` | the agent passed the conversation to a person | conversation id, reason |
| `onOpenProduct` | the shopper opened a product | `itemId`, `catalogId`, store |
| `onSessionExpired` | the chat session ended | return a fresh launch token to continue in place, or nil (a throw counts as nil, and the next expiry asks again). After three refused tokens in a row (asked again after 2 s and 4 s) the controller stops asking |
| `onMicrophonePermission` | the chat wants the microphone for voice | return whether iOS granted it; anything else denies |
| `onTiming` | the chat was shown and is usable | `open` in ms, `preloaded` |
| `onStateChange` | the chat's screen, its busy state or its basket changed (since 2.2.0) | `HephonChatState`: `view` (`.welcome`, `.conversation`), `busy`, `basketOpen`, `itemCount`, `conversationId` |
| `onClose` | the shopper tapped the chat's back arrow (`showBack`) | nothing. Without it, the view closes itself (see Open it as a full page) |

Events are delivered **at least once**: the package drops repeats by message id, and a cart
change's id is the same as the signed webhook's `webhook-id`, so a server that also takes
webhooks can match them. The webhook is the source of truth. Prices are decimal strings in
the store currency.

### Item ids: `itemId` and `catalogId`

A product has two of your ids, and the chat always sends both:

- `itemId`: the product's id **in the store of the session**. It is what a cart line or an
  order line there is keyed on. On a platform that keeps a row per store (a branch
  inventory id, a marketplace listing id) it is that row's id. On a platform with one id
  per product it equals the catalog id.
- `catalogId`: the product's id **in the catalog**, the same in every store.

**Key your cart on `itemId`.** Use `catalogId` for what is not about one store: your
product page's route, analytics, matching your catalog. Both are on the item of every cart
event, on each removed line of `onCartCleared`, on each line of `onCheckout` and on
`onOpenProduct`. `substituteItemId` is the substitute's id in the same store.

```swift
controller.onItemAdded = { event in
    if event.origin != .host { cart.set(event.item.itemId, event.item.quantity) }
}
controller.onItemRemoved = { event in
    if event.origin != .host { cart.remove(event.item.itemId) }
}
controller.onCheckout = { handoff in
    openCheckout(lines: handoff.items.map { ($0.itemId, $0.quantity) })
}
controller.onOpenProduct = { product in showProduct(catalogId: product.catalogId) }

// The same ids go back in the snapshot.
controller.sendCartSnapshot(cart.lines.map { CartSnapshotItem(itemId: $0.id, quantity: $0.quantity) })
```

### From your app to the chat

- `sendCartSnapshot([CartSnapshotItem(itemId: "7309008", quantity: 2)])`: sets each listed
  item's quantity in the chat's basket (0 removes it; an empty list empties it). Send it
  before you show the chat. Quantities over 99 are set to 99 and come back as `.host` events.
  A line names its item by the id your cart holds: `itemId`, or
  `CartSnapshotItem(catalogId: "48213", quantity: 2)` for a cart keyed on catalog ids. One
  of the two, never both. An empty id or a negative quantity stops in `init`
  (`precondition`).
- `setTheme(.dark)`: accepted; the chat stays light for now.
- `focus()`: puts the cursor in the message box. A hidden chat ignores it: call it after showing.
- `reload()`: loads the chat again after `pageState == .failed` (the view's Try again does it).

- `setAppearance(HephonAppearance(...))`: restyles the open chat, see Appearance below.
- `setText(HephonText(...))`: changes the open chat's words, see Text below.
- `sendMessage`, `newChat`, `openBasket`, `closeBasket`, `setStarters`, `setLocale`,
  `setRestrictions`: steer the chat, see Control the chat below.

Messages sent before the chat is ready are held and delivered on `ready`.

## Control the chat

Since 2.2.0 your app can drive the open chat and follow it:

```swift
// Sent as the shopper's message, as if typed. Dropped while a reply is on its way.
controller.sendMessage("Snacks for a movie night")
controller.newChat()                       // a new conversation with an empty chat basket
controller.openBasket()                    // and closeBasket()

// The welcome screen's suggestions, in place of the retailer's (up to six). Tapping one sends
// its prompt, or its label. An empty list brings the retailer's back.
controller.setStarters([
    HephonStarter(label: "Breakfast for 4"),
    HephonStarter(label: "Iftar essentials", prompt: "I need everything for an iftar for 6 people"),
])

// The shopper changed your app's language while the chat is loaded.
controller.setLocale("ar-AE")

// Kinds this chat never shows, added to the retailer's.
controller.setRestrictions([.alcohol, .alcoholFree])

controller.onStateChange = { state in
    header.showsBackToWelcome = state.view == .conversation
    header.badge = state.itemCount
    sendButton.isEnabled = !state.busy
}
```

- `starters:` and `restrictions:` can also be passed to `HephonAgentController(...)`. Like
  text, they are sent once the chat is ready, never on the chat URL.
- The last starters, restrictions and `setLocale` are sent again each time the chat loads
  again, so a reload keeps them. Messages, new chats and the basket are not.
- `sendMessage`, `setStarters` and `setLocale` return false (`@discardableResult`) and send
  nothing for what the chat would refuse: a message that is empty or over 2000 characters,
  more than six suggestions or one whose label is not 1 to 60 characters (`isValid`), a
  locale that is not a BCP 47 tag (`HostMessage.isLocale`).
- `HephonRestriction` is `.alcohol`, `.alcoholFree`, `.pork` or `.tobacco`. What the retailer
  excludes stays excluded whatever your app sends.
- Starters, like appearance and text, are ignored when the retailer switched app changes off
  in **Configure**; `onReady`'s `capabilities` then does not list `"starters"`.
- To draw your own first screen above the chat, open it with
  `HephonAppearance(showWelcome: false)` and send what the shopper picks with `sendMessage`.

## Open it as a full page

The chat can take the whole screen, with its own back arrow instead of a sheet's grabber.
Open it with `showBack: true` and keep the header (`showHeader` left as the retailer set it):

```swift
let controller = HephonAgentController(
    organization: "your-retailer",
    launch: .token(launchToken),
    appearance: HephonAppearance(showBack: true)
)
presenter.present(HephonAgentViewController(controller: controller, presentation: .fullScreen), animated: true)
```

SwiftUI:

```swift
.fullScreenCover(item: $assistant) { HephonAgentView(controller: $0) }
```

The back arrow posts `close`. When `onClose` is nil the view closes itself:
`HephonAgentViewController` is dismissed (or popped, when you pushed it on a navigation
controller) and `HephonAgentView` closes with SwiftUI's dismiss. Set `onClose` to close it
your own way. Full screen, the chat starts below the status bar; its message box keeps clear
of the home indicator.

## Appearance

Your app can restyle the chat it opens. Pass `appearance:` and the chat is drawn that way
from its first paint:

```swift
let controller = HephonAgentController(
    organization: "your-retailer",
    launch: .token(launchToken),
    appearance: HephonAppearance(scheme: .dark, primaryColor: "#1E1EF2", corners: .soft, header: .brand)
)
```

While it is open, `setAppearance` changes only the fields you set, over what your app sent
before. What it set is sent again when the chat loads again, so a reload keeps it:

```swift
controller.setAppearance(HephonAppearance(scheme: .light, showBasket: false))
```

**Colors**, each `"#RRGGBB"`:

| Field | What it colors |
|---|---|
| `primaryColor`, `deepColor`, `accentColor` | the brand colors |
| `dealColor` | deals and discounts |
| `ctaColor` | the main buttons (add, checkout) |
| `headerColor` | the header |
| `bubbleColor` | the shopper's message bubble |
| `surfaceColor` | the page behind the conversation |
| `cardColor` | product cards, the basket, the product sheet and menus |
| `textColor` | replies, titles, prices |
| `mutedColor` | small print |
| `lineColor` | the outlines of cards, chips and the message box |

**Shape and type**:

| Field | Values |
|---|---|
| `scheme` | `.light`, `.dark`, `.auto` (follows the device) |
| `corners` | `.round`, `.soft`, `.square` |
| `header` | `.plain`, `.brand` |
| `buttons` | `.pill`, `.rounded`, `.square` |
| `bubble` | `.brand`, `.soft` |
| `font` | `.geist`, `.manrope`, `.system` |
| `fontFamily` | a typeface the device already has, like `"Avenir Next"`, ahead of `font`. 1 to 40 letters, digits, spaces, dots, dashes or underscores. A name the device lacks falls back to `font` |
| `starterStyle` | `.photos`, `.list` |

**What is shown**, each `true` or `false`:

| Field | Part |
|---|---|
| `showHeader`, `showLogo` | the header, and the logo in it |
| `showBasket`, `showCheckout` | the whole basket, and its checkout button |
| `showBasketButton` | the basket button in the header |
| `showBasketBar` | the summary bar above the message box (item count, total, "View basket"). An app with its own cart bar sets it `false` |
| `showNewChat` | the new chat button |
| `showFollowUps` | the suggested replies under an answer |
| `showSteps` | the agent's steps while it works |
| `productSheet` | tapping a product opens its sheet in the chat |
| `addFromCards` | a product card has its own add button |
| `showAssistantName` | the name above each reply |
| `showStarters` | the suggested first messages on the welcome screen |
| `showWelcome` | the welcome screen's title, line and suggestions. `false` when your app draws its own first screen (since 2.2.0) |
| `showBack` | a back arrow before the logo that closes the chat, for a chat opened as a full page (since 2.2.0) |
| `showPoweredBy` | "Powered by Hephon"; takes effect only where Hephon allows the retailer to hide it (since 2.2.0) |
| `hideOrderHelp` | `true` hides "Help with an order" |
| `hideVoice` | `true` hides the microphone: voice messages and dictation |
| `hideCall` | `true` hides the live voice call |

The last three are named `hide` because that is all an app can do with them: what the
retailer has switched off stays off.

Every field is optional: one you leave out keeps what the retailer set in Hephon. A color
that is not `#RRGGBB` stops a debug build in `HephonAppearance.init` (`assertionFailure`),
so a typo shows the first time the code runs. A release build never crashes on one: it
drops that color and the chat keeps the retailer's. `HephonAppearance.isColor(_:)` checks
a color that comes from outside your code. A `fontFamily` that is not a typeface name is
treated the same way, and `HephonAppearance.isFontFamily(_:)` checks one.

The retailer can switch app changes off in **Configure**. The chat then ignores both the
option and `setAppearance`, and `onReady`'s `capabilities` does not list `"appearance"`.

## Text

Your app can change the chat's words, at open or while it is open:

```swift
let controller = HephonAgentController(
    organization: "your-retailer",
    launch: .token(launchToken),
    text: HephonText(
        welcomeTitle: "What can we get you?",
        placeholder: "Ask Suppy",
        labels: .init(viewBasket: "View cart", checkout: "Go to checkout")
    )
)

controller.setText(HephonText(labels: .init(addToBasket: "Add to cart")))
```

| Field | Where |
|---|---|
| `welcomeTitle`, `welcomeSubtitle` | the empty chat |
| `placeholder` | the message box |
| `tagline` | under the retailer's name in the header |
| `assistantName` | the name in the header and above each reply (up to 40 characters) |
| `labels` | `viewBasket`, `basketTitle`, `checkout`, `addToBasket`, `orderHelp`, `newChat`, `total`, `emptyBasket`, `thinking`, `typing`, `tryAgain` |

Every field is optional, and `setText` changes only what you set, the labels one by one.
Text is sent to the chat as a message once it is ready, never on the chat URL, so it shows
a moment after the first paint. The controller keeps what you set and sends it again each
time the chat loads again. Send the text in the shopper's language: the chat does not
translate it.

When the retailer has switched app changes off in **Configure**, the chat ignores it and
`onReady`'s `capabilities` does not list `"text"`.

## Launch tokens

Your server signs a short-lived JWT with an Ed25519 private key. Register the public key
(JWK) in Hephon on the **Install** screen, under launch tokens. Never ship the private key in the app.

Header: `{ "alg": "EdDSA", "typ": "hephon-launch+jwt", "kid": "<your key id>" }`.

| Claim | Value |
|---|---|
| `iss` | your partner slug, or the retailer's slug |
| `aud` | `hephon:<retailer slug>` |
| `sub` | your shopper id (optional, never an email or phone; `wa:` is reserved) |
| `hsid` | your app's session id (optional, echoed in cart events and checkout) |
| `store` | the store (branch) id the chat opens in |
| `locale` | optional BCP 47 hint |
| `iat`, `exp` | at most 5 minutes apart |
| `jti` | unique per token: a token is refused the second time |

The Install screen has the signing code for Node, and the Flutter package's README for Dart.

## Security

- The bridge handler is added before the first load, in the page's content world. A message
  counts only from the main frame on the Hephon host or a custom domain you passed.
- Messages to the chat go through `callAsyncJavaScript` with arguments (never string
  concatenation), and only while the web view shows the chat.
- The web view shows only the chat (`/c/<organization>`). Every other link, including the
  chat's own privacy page, `target="_blank"` links and `window.open`, opens in Safari or the
  app it belongs to. `javascript:` and `data:` navigations are blocked.
- The microphone is granted only for a microphone-only request from an allowed origin and
  only when `onMicrophonePermission` returns true. Camera requests are refused; WebKit's own
  prompt never shows.
- Web Inspector can attach in debug builds (`isInspectable`, iOS 16.4+).

## Test it

- The retailer's **Install** screen, **Test** step: **Get a test code** gives a code that
  opens one chat for 5 minutes. Pass it as `.code("...")`, ask the assistant for milk and add
  it: your `onItemAdded` runs, and the Install screen shows your app and its version.
- `Example/` is a small SwiftUI app that loads the chat ahead, keeps it between opens and
  lists every event with its open time. Open `Example/HephonCommerceExample.xcodeproj`, run
  it on a simulator, and paste a test code.
- `xcodebuild test -scheme HephonCommerce -destination 'platform=iOS Simulator,name=iPhone 17'`
  runs the contract tests (the bridge, host, appearance and control fixtures every Hephon SDK shares) and the
  controller tests.
- On an iOS 18.4 to 18.x simulator, an app whose deployment target is older than the
  simulator's iOS stops at launch with `Library not loaded: /usr/lib/swift/libswiftWebKit.dylib`.
  That is an Xcode simulator bug with WebKit's Swift API, not this package: devices are not
  affected. Use an iOS 26 (or 18.3 or older) simulator.
