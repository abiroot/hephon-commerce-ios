import Foundation
import XCTest

/// The contract fixtures (`Fixtures/*.json`, byte-identical copies of
/// packages/embed/fixtures, checked by scripts/check-sdk-fixtures.ts).
enum Fixture {
    static func object(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Fixtures/\(name).json is missing from the test bundle"
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func list(_ name: String, _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(object(name)[key] as? [[String: Any]], "\(name).\(key) is not a list")
    }

    /// The first page-to-host message of `type`, as JSON text, with `changes` applied.
    static func page(_ type: String, _ changes: [String: Any] = [:]) throws -> String {
        let message = try XCTUnwrap(
            list("bridge_v1", "pageToHost").first { $0["type"] as? String == type },
            "bridge_v1.json has no \(type)"
        )
        return json(message.merging(changes) { $1 })
    }

    /// `value` as JSON text; a string becomes a JSON string literal (for a page script).
    static func json(_ value: Any) -> String {
        // Fixture values are JSON already.
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}
