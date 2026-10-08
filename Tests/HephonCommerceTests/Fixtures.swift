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

    /// The first page-to-host message of `type` in the fixture `name`, as JSON text, with
    /// `changes` applied.
    static func page(_ type: String, _ changes: [String: Any] = [:], in name: String = "bridge_v1") throws -> String {
        let message = try XCTUnwrap(
            list(name, "pageToHost").first { $0["type"] as? String == type },
            "\(name).json has no \(type)"
        )
        return json(message.merging(changes) { $1 })
    }

    /// `value` as JSON text; a string becomes a JSON string literal (for a page script).
    static func json(_ value: Any) -> String {
        // Fixture values are JSON already.
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}

// MARK: - Waiting for the controller's tasks

/// Lets every queued main-actor task run.
@MainActor
func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}

/// Runs queued main-actor tasks until `condition` holds.
@MainActor
func until(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0 ..< 2000 where !condition() {
        await Task.yield()
    }
    XCTAssertTrue(condition(), "timed out", file: file, line: line)
}

/// Waits for WebKit, which answers from another process. Up to two minutes: its first launch
/// on a simulator that has just booted (CI) takes more than twenty seconds.
@MainActor
func untilWebKit(
    seconds: Int = 120, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
) async {
    for _ in 0 ..< seconds * 20 where !condition() {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(condition(), "timed out", file: file, line: line)
}
