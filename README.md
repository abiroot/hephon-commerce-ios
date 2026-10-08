# HephonCommerce for iOS

Put the Hephon Commerce shopping agent in your iOS app. The agent runs in a `WKWebView` on
the retailer's chat page; this package opens it for one shopper, keeps it on Hephon's
origin, and turns everything it does to the basket into typed callbacks in **your own item
ids**, so your app's cart and checkout stay in charge.

- `HephonAgentController`: one chat for one shopper (launch token or code, callbacks, cart
  snapshot, theme, focus). An `ObservableObject` with `@Published pageState`. Call
  `preload()` and the chat is loaded before the shopper taps, and stays loaded between opens.
- `HephonAgentViewController`: the chat with loading and retry states. Presented, it is a
  full-height sheet with a grabber.
- `HephonAgentView`: the same for SwiftUI, for `.sheet` or a screen of its own.

iOS 15 or later, Xcode 16 or later. No dependencies.

## Install

**Xcode:** File > Add Package Dependencies, paste

```
https://github.com/abiroot/hephon-commerce-ios.git
```

set Dependency Rule to **Up to Next Major Version** from `1.1.0`, and add `HephonCommerce`
to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/abiroot/hephon-commerce-ios.git", from: "1.1.0"),
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
screen), then raise the rule's lower bound (`from: "2.0.0"`). The Install screen shows which
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
| `onItemAdded` / `onItemUpdated` / `onItemRemoved` | a basket line changed (by the agent, the shopper, or your snapshot) | `CartItemEvent`: `item.itemId`, `quantity`, `previousQuantity`, `unitPrice`, `currency`, `origin` |
| `onCartCleared` | the basket was emptied | the removed lines |
| `onCheckout` | the shopper tapped checkout | `CartHandoff` with every line in your ids, total, currency, substitutions |
| `onHandoff` | the agent passed the conversation to a person | conversation id, reason |
| `onOpenProduct` | the shopper opened a product | item id |
| `onSessionExpired` | the chat session ended | return a fresh launch token to continue in place, or nil (a throw counts as nil, and the next expiry asks again). After three refused tokens in a row (asked again after 2 s and 4 s) the controller stops asking |
| `onMicrophonePermission` | the chat wants the microphone for voice | return whether iOS granted it; anything else denies |
| `onTiming` | the chat was shown and is usable | `open` in ms, `preloaded` |
| `onClose` | the chat asked to close (web widget today) | |

Events are delivered **at least once**: the package drops repeats by message id, and a cart
change's id is the same as the signed webhook's `webhook-id`, so a server that also takes
webhooks can match them. The webhook is the source of truth. Prices are decimal strings in
the store currency.

### From your app to the chat

- `sendCartSnapshot([CartSnapshotItem(itemId: "48213", quantity: 2)])`: sets each listed
  item's quantity in the chat's basket (0 removes it; an empty list empties it). Send it
  before you show the chat. Quantities over 99 are set to 99 and come back as `.host` events.
- `setTheme(.dark)`: accepted; the chat stays light for now.
- `focus()`: puts the cursor in the message box. A hidden chat ignores it: call it after showing.
- `reload()`: loads the chat again after `pageState == .failed` (the view's Try again does it).

Messages sent before the chat is ready are held and delivered on `ready`.

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
  runs the contract tests (the bridge and host fixtures every Hephon SDK shares) and the
  controller tests.
- On an iOS 18.4 to 18.x simulator, an app whose deployment target is older than the
  simulator's iOS stops at launch with `Library not loaded: /usr/lib/swift/libswiftWebKit.dylib`.
  That is an Xcode simulator bug with WebKit's Swift API, not this package: devices are not
  affected. Use an iOS 26 (or 18.3 or older) simulator.
