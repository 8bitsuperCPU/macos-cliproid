import Testing
import Foundation
@testable import ClipRoidKit
import ClipRoidCore

@Suite("Settings")
@MainActor
struct SettingsStoreTests {
    /// An isolated suite per test, so the developer's real preferences are never touched and tests
    /// cannot contaminate each other through shared global state.
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ClipRoidSettingsTests-\(UUID().uuidString)")!
    }

    @Test("Defaults are sensible on a fresh install")
    func freshDefaults() {
        let settings = SettingsStore(defaults: scratchDefaults())
        #expect(settings.shelfPosition == .top)
        #expect(settings.shelfItemCount == 10)
        #expect(settings.sensitiveDetectionEnabled)
        #expect(settings.hideSecretsFromShelf)
        #expect(settings.captureImages)
    }

    @Test("Changes persist across a restart")
    func persists() {
        let defaults = scratchDefaults()
        do {
            let settings = SettingsStore(defaults: defaults)
            settings.shelfPosition = .right
            settings.shelfItemCount = 15
            settings.sensitiveDetectionEnabled = false
        }
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.shelfPosition == .right)
        #expect(reloaded.shelfItemCount == 15)
        #expect(!reloaded.sensitiveDetectionEnabled)
    }

    /// Spec §4.19 allows 5–20. Clamping on write means a corrupt or hand-edited plist cannot
    /// produce a shelf of 10,000 items, which would hang the UI rather than fail visibly.
    @Test("Shelf item count is clamped to the allowed range", arguments: [
        (0, 5), (4, 5), (5, 5), (12, 12), (20, 20), (21, 20), (10_000, 20),
    ])
    func clampsItemCount(input: Int, expected: Int) {
        let settings = SettingsStore(defaults: scratchDefaults())
        settings.shelfItemCount = input
        #expect(settings.shelfItemCount == expected)
    }

    /// A value written by a future version must degrade to the default rather than failing to
    /// decode and taking the settings window down with it.
    @Test("An unknown stored position falls back to the default")
    func unknownPositionFallsBack() {
        let defaults = scratchDefaults()
        defaults.set("dynamic-island", forKey: "shelf.position")
        #expect(SettingsStore(defaults: defaults).shelfPosition == .top)
    }

    @Test("Retention policy reflects the settings, with 0 meaning unlimited")
    func buildsRetentionPolicy() {
        let settings = SettingsStore(defaults: scratchDefaults())
        settings.maxClipCount = 500
        settings.maxClipAgeDays = 30
        #expect(settings.retentionPolicy.maxClipCount == 500)
        #expect(settings.retentionPolicy.maxAgeDays == 30)

        settings.maxClipCount = 0
        settings.maxClipAgeDays = 0
        #expect(settings.retentionPolicy.maxClipCount == nil)
        #expect(settings.retentionPolicy.maxAgeDays == nil)
        #expect(settings.retentionPolicy.isUnlimited)
    }

    @Test("Turning off secret hiding lets secrets onto the shelf")
    func secretHidingIsOptional() {
        let settings = SettingsStore(defaults: scratchDefaults())
        settings.hideSecretsFromShelf = false
        #expect(!settings.hideSecretsFromShelf)
    }
}
