import AVFAudio
import HephonCommerce
import SwiftUI

/// A small shop: its own cart, kept in step with the agent through the callbacks, and a log of
/// every bridge event. In a real app your server signs a launch token for every open; here you
/// paste a code (Install screen, Test, Get a test code) or a token, or leave it empty for an
/// anonymous chat.
///
/// Defaults come from the scheme's environment: HEPHON_HOST (the local dev server unless set)
/// and HEPHON_ORG.
struct ShopView: View {
    @AppStorage("host") private var host = ProcessInfo.processInfo.environment["HEPHON_HOST"] ?? "http://localhost:3051"
    @AppStorage("organization") private var organization = ProcessInfo.processInfo.environment["HEPHON_ORG"] ?? "suppy"
    @State private var launch = ""
    @StateObject private var shop = Shop()

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
                    Button("Ask the assistant") {
                        shop.open(host: host, organization: organization, launch: launch)
                        launch = ""
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
        .sheet(item: $shop.assistant) { HephonAgentView(controller: $0) }
    }
}

@MainActor
final class Shop: ObservableObject {
    struct Event: Identifiable {
        let id = UUID()
        let text: String
    }

    /// The open chat; the sheet clears it when the shopper closes it.
    @Published var assistant: HephonAgentController?
    @Published private(set) var cart: [String: Int] = [:]
    @Published private(set) var events: [Event] = []
    @Published private(set) var problem: String?

    func open(host: String, organization: String, launch: String) {
        guard let url = URL(string: host.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            problem = "Enter a host like https://commerce.hephon.ai"
            return
        }
        problem = nil
        let value = launch.trimmingCharacters(in: .whitespaces)
        let controller = HephonAgentController(
            host: url,
            organization: organization.trimmingCharacters(in: .whitespaces),
            // A launch token is a JWT: three dot-separated parts.
            launch: value.isEmpty ? nil : value.split(separator: ".").count == 3 ? .token(value) : .code(value),
            locale: Locale.preferredLanguages.first
        )
        controller.onReady = { [weak self, weak controller] ready in
            guard let self else { return }
            record("ready: store \(ready.storeId)")
            // Start the agent from what the shopper already has.
            controller?.sendCartSnapshot(cart.map { CartSnapshotItem(itemId: $0.key, quantity: $0.value) })
        }
        controller.onItemAdded = { [weak self] event in
            self?.apply(event)
            self?.record("onItemAdded \(event.item.itemId) x\(event.item.quantity) (\(event.origin.rawValue))")
        }
        controller.onItemUpdated = { [weak self] event in
            self?.apply(event)
            self?.record("onItemUpdated \(event.item.itemId) \(event.item.previousQuantity) -> \(event.item.quantity)")
        }
        controller.onItemRemoved = { [weak self] event in
            self?.apply(event)
            self?.record("onItemRemoved \(event.item.itemId)")
        }
        controller.onCartCleared = { [weak self] cleared in
            self?.cart.removeAll()
            self?.record("onCartCleared \(cleared.removed.count) lines")
        }
        controller.onCheckout = { [weak self] handoff in
            self?.record("onCheckout \(handoff.items.count) lines, \(handoff.total) \(handoff.currency)")
            self?.assistant = nil
        }
        controller.onHandoff = { [weak self] handoff in self?.record("onHandoff \(handoff.reason ?? "")") }
        controller.onOpenProduct = { [weak self] product in self?.record("onOpenProduct \(product.itemId)") }
        controller.onSessionExpired = { [weak self] in
            // Ask your server for a fresh launch token here.
            self?.record("onSessionExpired")
            return nil
        }
        controller.onClose = { [weak self] in self?.assistant = nil }
        controller.onMicrophonePermission = {
            if #available(iOS 17, *) { return await AVAudioApplication.requestRecordPermission() }
            return await withCheckedContinuation { done in
                AVAudioSession.sharedInstance().requestRecordPermission { @Sendable granted in done.resume(returning: granted) }
            }
        }
        assistant = controller
    }

    private func apply(_ event: CartItemEvent) {
        cart[event.item.itemId] = event.item.quantity == 0 ? nil : event.item.quantity
    }

    private func record(_ text: String) {
        print("Hephon", text)
        events.insert(Event(text: text), at: 0)
    }
}
