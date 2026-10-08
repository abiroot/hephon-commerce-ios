#if DEBUG
    @testable import HephonCommerce
    import UIKit

    /// Scripted runs for the device checks of the preload work (docs/integrations/SDK-PRELOAD.md
    /// 7.2 in the Hephon repository). Nothing runs unless the app is launched with HEPHON_RUN:
    ///
    ///     SIMCTL_CHILD_HEPHON_RUN=preloaded xcrun simctl launch --console booted ai.hephon.commerce.example
    ///
    /// - `cold`, `preloaded`, `reopen`: HEPHON_N opens (5), each printed with its `onTiming`.
    /// - `stream`: sends HEPHON_SAY, closes the sheet while the reply streams, watches the hidden
    ///   page, reopens, then reloads the chat while it is shown.
    ///
    /// HEPHON_MARK=1 flashes a red bar at each open, to find the tap in a screen recording.
    /// The module is imported `@testable` to read the page of a chat that is in no view.
    @MainActor
    enum Measure {
        private static let environment = ProcessInfo.processInfo.environment
        private static let start = Date()

        static func run(_ shop: Shop, _ chat: Shop.Chat) async {
            guard let row = environment["HEPHON_RUN"] else {
                return
            }
            let opens = Int(environment["HEPHON_N"] ?? "") ?? 5
            // Statics are lazy: start the log's clock now.
            _ = start
            // Let the screen's own preload settle, then start from nothing.
            await pause(2)
            shop.forget()
            switch row {
            case "cold":
                for _ in 1 ... opens {
                    await open(shop, chat, keep: false, row)
                    await close(shop)
                }
            case "preloaded":
                for _ in 1 ... opens {
                    await preload(shop, chat)
                    await open(shop, chat, keep: true, row)
                    await close(shop)
                    shop.forget()
                }
            case "reopen":
                await preload(shop, chat)
                await open(shop, chat, keep: true, "first")
                for _ in 1 ... opens {
                    await close(shop)
                    await open(shop, chat, keep: true, row)
                }
            case "stream":
                await stream(shop, chat)
            default:
                log("unknown HEPHON_RUN \(row)")
            }
            log("done")
        }

        private static func preload(_ shop: Shop, _ chat: Shop.Chat) async {
            let readies = shop.readies
            shop.preload(chat)
            await wait { shop.readies > readies }
            await log("ready while hidden: \(page(shop))")
            await pause(1)
        }

        private static func open(_ shop: Shop, _ chat: Shop.Chat, keep: Bool, _ row: String) async {
            let timings = shop.timings.count
            mark(true)
            shop.open(chat, keep: keep)
            await wait { shop.timings.count > timings }
            let timing = shop.timings.last
            log("\(row) open=\(timing?.open.map(String.init) ?? "nil") preloaded=\(timing?.preloaded ?? false)")
            await pause(1.5)
        }

        private static func close(_ shop: Shop) async {
            mark(false)
            shop.presented = nil
            await pause(1.5)
        }

        private static func stream(_ shop: Shop, _ chat: Shop.Chat) async {
            await preload(shop, chat)
            await open(shop, chat, keep: true, "first")
            let say = environment["HEPHON_SAY"] ?? "add 2 bottles of water to my cart"
            _ = await script(shop, """
            const box = document.querySelector('textarea[aria-label="Message"]');
            Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value").set.call(box, say);
            box.dispatchEvent(new Event("input", { bubbles: true }));
            setTimeout(() => box.form.requestSubmit(), 50);
            """, ["say": say])
            await pause(Double(environment["HEPHON_CLOSE_AFTER"] ?? "") ?? 0.8)
            log("closing while the reply streams: \(await page(shop))")
            shop.presented = nil
            for _ in 1 ... 12 {
                await pause(1)
                log("hidden: \(await page(shop))")
            }
            await open(shop, chat, keep: true, "after the stream")
            log("shown again: \(await page(shop))")
            let readies = shop.readies
            shop.kept?.controller.reload()
            await wait { shop.readies > readies }
            await pause(3)
            log("reloaded while shown: \(await page(shop))")
            await close(shop)
        }

        /// What the chat page says about itself, wherever its web view is.
        private static func page(_ shop: Shop) async -> String {
            await script(shop, """
            return [
                document.visibilityState,
                innerWidth + "x" + innerHeight,
                "text " + document.body.innerText.length,
                "alerts " + document.querySelectorAll('[role="alert"]').length,
                "events " + performance.getEntriesByType("resource").filter((e) => e.name.includes("/events")).length,
            ].join(", ");
            """)
        }

        private static func script(_ shop: Shop, _ body: String, _ arguments: [String: Any] = [:]) async -> String {
            guard let controller = shop.kept?.controller else {
                return "no chat"
            }
            return await withCheckedContinuation { done in
                controller.webView().callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                    done.resume(returning: (try? result.get()).map { "\($0)" } ?? "\(result)")
                }
            }
        }

        private static func mark(_ on: Bool) {
            guard environment["HEPHON_MARK"] != nil,
                  let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow
            else {
                return
            }
            window.viewWithTag(4711)?.removeFromSuperview()
            if on {
                let bar = UIView(frame: CGRect(x: 0, y: 0, width: window.bounds.width, height: 40))
                bar.backgroundColor = .red
                bar.tag = 4711
                window.addSubview(bar)
            }
        }

        private static func wait(_ condition: () -> Bool) async {
            for _ in 0 ..< 3000 where !condition() {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        private static func pause(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        private static func log(_ text: String) {
            print("HephonRun", String(format: "%7.2f", Date().timeIntervalSince(start)), text)
        }
    }
#endif
