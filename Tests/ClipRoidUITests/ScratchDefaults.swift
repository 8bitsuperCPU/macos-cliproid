import Foundation

/// Defaults held in memory, so tests never touch the developer's real preferences and cannot
/// contaminate each other.
///
/// Not `UserDefaults(suiteName:)`: every suite is a plist in ~/Library/Preferences, and a
/// UUID-named one per test left thousands behind. Deleting them is not reliable either — cfprefsd
/// writes asynchronously, even after the test process exits, and recreates files already removed.
///
/// Overriding these three is enough: Foundation's typed accessors (`bool(forKey:)`,
/// `set(_: Double, forKey:)`, …) all route through them.
final class ScratchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
