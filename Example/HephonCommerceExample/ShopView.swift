import AVFAudio
import HephonCommerce
import SwiftUI

/// A small shop: its own cart, kept in step with the agent through the callbacks, and a log of
/// every bridge event. The chat is loaded when this screen appears and stays loaded between
/// opens, so the assistant opens at once; turn that off to open it as SDK 1.0.0 did.
///
/// In a real app your server signs a launch token for the shopper; here you paste a code
/// (Install screen, Test, Get a test code) or a token, or leave it empty for an anonymous chat.
///
/// Defaults come from the scheme's environment: HEPHON_HOST (the local dev server unless set)
/// and HEPHON_ORG.
struct ShopView: View {
    @AppStorage("host") private var host = ProcessInfo.processInfo.environment["HEPHON_HOST"] ?? "http://localhost:3051"
    @AppStorage("organization") private var organization = ProcessInfo.processInfo.environment["HEPHON_ORG"] ?? "suppy"
    @AppStorage("keep") private var keep = true
    @State private var launch = ""
    @StateObject private var shop = Shop()
    @Environment(\.scenePhase) private var scenePhase

    private var chat: Shop.Chat {
        Shop.Chat(host: host, organization: organization, launch: launch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host", text: $host)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    TextField("Organization", text: $organization)
                    TextField("Launch code or token", text: $launch)
                } header: {
                    Text("Chat")
                } footer: {
                    Text("Empty opens an anonymous chat. A code or token works once.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section {
                    Toggle("Load ahead and keep between opens", isOn: $keep)
                    Button("Ask the assistant") {
                        shop.open(chat, keep: keep)
                        if !keep {
                            launch = ""
                        }
                    }
                    // Opens the chat and sends a message for the shopper, as if typed.
                    Button("Ask for snacks") {
                        shop.open(chat, keep: keep, asking: "Snacks for a movie night")
                        if !keep {
                            launch = ""
                        }
                    }
                    if let problem = shop.problem {
                        Text(problem).foregroundStyle(.red)
                    }
                }

                Section("Cart") {
                    if shop.cart.isEmpty {
                        Text("Empty").foregroundStyle(.secondary)
                    }
                    ForEach(shop.cart.keys.sorted(), id: \.self) { item in
                        LabeledContent("Item \(item)", value: "x\(shop.cart[item] ?? 0)")
                    }
                }

                Section("Bridge events") {
                    if shop.events.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(shop.events) { event in
                        Text(event.text).font(.callout.monospaced())
                    }
                }
            }
            .navigationTitle("Demo shop")
        }
        .sheet(item: $shop.presented) { HephonAgentView(controller: $0) }
        // Where the assistant is likely to be opened, each time the screen is back: a hidden
        // chat is released after 10 minutes and on a memory warning.
        .onAppear(perform: preload)
        .onChange(of: scenePhase) { _ in preload() }
        .onChange(of: keep) { _ in preload() }
        #if DEBUG
            .task { await Measure.run(shop, chat) }
        #endif
    }

    private func preload() {
        if keep, scenePhase == .active {
            shop.preload(chat)
        } else if !keep {
            shop.forget()
        }
    }
}

@MainActor
final class Shop: ObservableObject {
    struct Event: Identifiable {
        let id = UUID()
        let text: String
    }

    /// Which chat to open: the fields of the form.
    struct Chat: Equatable {
        var host: String
        var organization: String
        var launch: String
    }

    /// The chat on screen; the sheet clears it when the shopper closes it.
    @Published var presented: HephonAgentController?
    @Published private(set) var cart: [String: Int] = [:]
    @Published private(set) var events: [Event] = []
    @Published private(set) var problem: String?
    /// Every `onReady` and `onTiming`, for the scripted runs.
    private(set) var readies = 0
    private(set) var timings: [HephonOpenTiming] = []

    /// The chat that stays loaded between opens, and what it was made for.
    private(set) var kept: (chat: Chat, controller: HephonAgentController)?

    /// Loads the chat ahead of the tap.
    func preload(_ chat: Chat) {
        keeping(chat)?.preload()
    }

    func open(_ chat: Chat, keep: Bool, asking message: String? = nil) {
        let controller: HephonAgentController?
        if keep {
            controller = keeping(chat)
            // Dismissing the sheet then hides the chat instead of ending it.
            controller?.preload()
        } else {
            forget()
            controller = make(chat)
        }
        guard let controller else {
            return
        }
        // Start the agent from what the shopper already has: held until the chat is ready.
        controller.sendCartSnapshot(cart.map { CartSnapshotItem(itemId: $0.key, quantity: $0.value) })
        if let message {
            controller.sendMessage(message)
        }
        presented = controller
    }

    /// Ends the kept chat: on logout in a real app, or when the form names another chat.
    func forget() {
        kept?.controller.dispose()
        kept = nil
    }

    private func keeping(_ chat: Chat) -> HephonAgentController? {
        if kept?.chat != chat {
            forget()
            kept = make(chat).map { (chat, $0) }
        }
        return kept?.controller
    }

    private func make(_ chat: Chat) -> HephonAgentController? {
        guard let url = URL(string: chat.host.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            problem = "Enter a host like https://commerce.hephon.ai"
            return nil
        }
        problem = nil
        let value = chat.launch.trimmingCharacters(in: .whitespaces)
        let controller = HephonAgentController(
            host: url,
            organization: chat.organization.trimmingCharacters(in: .whitespaces),
            // A launch token is a JWT: three dot-separated parts.
            launch: value.isEmpty ? nil : value.split(separator: ".").count == 3 ? .token(value) : .code(value),
            locale: Locale.preferredLanguages.first,
            // The welcome screen's suggestions, in place of the retailer's.
            starters: [
                HephonStarter(label: "Breakfast for 4"),
                HephonStarter(label: "Movie night", prompt: "Snacks for a movie night for 4 people"),
            ]
        )
        controller.onReady = { [weak self] ready in
            self?.readies += 1
            self?.record("ready: store \(ready.storeId)")
        }
        controller.onStateChange = { [weak self] state in
            self?.record(
                "onStateChange \(state.view.rawValue)\(state.busy ? ", busy" : ""), basket \(state.itemCount)\(state.basketOpen ? " (open)" : "")"
            )
        }
        controller.onTiming = { [weak self] timing in
            self?.timings.append(timing)
            self?.record("opened in \(timing.open.map { "\($0) ms" } ?? "?")\(timing.preloaded ? ", preloaded" : "")")
        }
        controller.onItemAdded = { [weak self] event in
            self?.apply(event)
            self?.record("onItemAdded \(Self.name(event.item)) x\(event.item.quantity) (\(event.origin.rawValue))")
        }
        controller.onItemUpdated = { [weak self] event in
            self?.apply(event)
            self?.record("onItemUpdated \(Self.name(event.item)) \(event.item.previousQuantity) -> \(event.item.quantity)")
        }
        controller.onItemRemoved = { [weak self] event in
            self?.apply(event)
            self?.record("onItemRemoved \(Self.name(event.item))")
        }
        controller.onCartCleared = { [weak self] cleared in
            self?.cart.removeAll()
            self?.record("onCartCleared \(cleared.removed.count) lines")
        }
        controller.onCheckout = { [weak self] handoff in
            self?.record("onCheckout \(handoff.items.count) lines, \(handoff.total) \(handoff.currency)")
            self?.presented = nil
        }
        controller.onHandoff = { [weak self] handoff in self?.record("onHandoff \(handoff.reason ?? "")") }
        controller.onOpenProduct = { [weak self] product in
            self?.record("onOpenProduct \(product.itemId) (catalog \(product.catalogId))")
        }
        controller.onSessionExpired = { [weak self] in
            // Ask your server for a fresh launch token here. With a launch token and
            // preload(), it is also asked each time the chat loads again.
            self?.record("onSessionExpired")
            return nil
        }
        controller.onClose = { [weak self] in self?.presented = nil }
        controller.onMicrophonePermission = {
            if #available(iOS 17, *) { return await AVAudioApplication.requestRecordPermission() }
            return await withCheckedContinuation { done in
                AVAudioSession.sharedInstance().requestRecordPermission { @Sendable granted in done.resume(returning: granted) }
            }
        }
        return controller
    }

    /// The item of a cart event: its id in this store, which the cart is keyed on, and its
    /// id in the catalog.
    private static func name(_ item: CartItem) -> String {
        "\(item.itemId) (catalog \(item.catalogId))"
    }

    private func apply(_ event: CartItemEvent) {
        cart[event.item.itemId] = event.item.quantity == 0 ? nil : event.item.quantity
    }

    private func record(_ text: String) {
        print("Hephon", text)
        events.insert(Event(text: text), at: 0)
    }
}
