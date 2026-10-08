# HephonCommerce for iOS

Put the Hephon Commerce shopping agent in your iOS app. The agent runs in a `WKWebView` on
the retailer's chat page; this package opens it for one shopper, keeps it on Hephon's
origin, and turns everything it does to the basket into typed callbacks in **your own item
ids**, so your app's cart and checkout stay in charge.

- `HephonAgentController`: one chat for one shopper (launch token or code, callbacks, cart
  snapshot, theme, focus). An `ObservableObject` with `@Published pageState`.
- `HephonAgentViewController`: the chat with loading and retry states. Presented, it is a
  full-height sheet with a grabber.
- `HephonAgentView`: the same for SwiftUI, for `.sheet` or a screen of its own.

iOS 15 or later, Xcode 16 or later. No dependencies.

## Install

**Xcode:** File > Add Package Dependencies, paste

```
https://github.com/abiroot/hephon-commerce-ios.git
```

set Dependency Rule to **Up to Next Major Version** from `1.0.0`, and add `HephonCommerce`
to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/abiroot/hephon-commerce-ios.git", from: "1.0.0"),
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
    controller.onReady = { [weak controller] _ in controller?.sendCartSnapshot(cart.snapshot()) }
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

Make a **new controller for every open**: a launch token or code works once. Dismissing the
sheet disposes the controller: that unloads the chat, so a live call or a spoken reply stops
with it. Callbacks that use the controller capture it `[weak controller]`.

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
| `onClose` | the chat asked to close (web widget today) | |

Events are delivered **at least once**: the package drops repeats by message id, and a cart
change's id is the same as the signed webhook's `webhook-id`, so a server that also takes
webhooks can match them. The webhook is the source of truth. Prices are decimal strings in
the store currency.

### From your app to the chat

- `sendCartSnapshot([CartSnapshotItem(itemId: "48213", quantity: 2)])`: sets each listed
  item's quantity in the chat's basket (0 removes it; an empty list empties it). Send it on
  `onReady`. Quantities over 99 are set to 99 and come back as `.host` events.
- `setTheme(.dark)`: accepted; the chat stays light for now.
- `focus()`: puts the cursor in the message box.
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
- `Example/` is a small SwiftUI app that opens a launch code and lists every event. Open
  `Example/HephonCommerceExample.xcodeproj`, run it on a simulator, and paste a test code.
- `xcodebuild test -scheme HephonCommerce -destination 'platform=iOS Simulator,name=iPhone 17'`
  runs the contract tests (the bridge and host fixtures every Hephon SDK shares) and the
  controller tests.
- On an iOS 18.4 to 18.x simulator, an app whose deployment target is older than the
  simulator's iOS stops at launch with `Library not loaded: /usr/lib/swift/libswiftWebKit.dylib`.
  That is an Xcode simulator bug with WebKit's Swift API, not this package: devices are not
  affected. Use an iOS 26 (or 18.3 or older) simulator.
