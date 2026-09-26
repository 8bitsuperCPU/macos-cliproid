import Testing
import Foundation
@testable import ClipRoidKit
import ClipRoidCore

@Suite("Settings")
@MainActor
struct SettingsStoreTests {
    /// The flag has to make the feature unreachable, not merely invisible. AppEnvironment starts
    /// the keystroke tap from `inlineShortcutsEnabled`, so a user who had already switched
    /// shortcuts on would otherwise keep the tap running with the Settings pane now hidden — the
    /// worst of both: a keystroke observer they can neither see nor turn off.
    @Test("While the feature flag is off, inline shortcuts cannot be enabled")
    func inlineShortcutsStayOffBehindTheFlag() {
        let defaults = ScratchDefaults()
        // Somebody who had turned the feature on before it was withdrawn.
        defaults.set(true, forKey: "shortcuts.enabled")
        let settings = SettingsStore(defaults: defaults)

        if FeatureFlags.inlineShortcuts {
            #expect(settings.inlineShortcutsEnabled, "flag is on, so the stored choice applies")
        } else {
            #expect(!settings.inlineShortcutsEnabled)
            settings.inlineShortcutsEnabled = true
            #expect(!settings.inlineShortcutsEnabled, "not even an explicit set can turn it on")
            // The preference itself survives, so flipping the flag back restores the user's
            // choice rather than silently resetting everyone to off.
            #expect(defaults.bool(forKey: "shortcuts.enabled"))
        }
    }

    @Test("Defaults are sensible on a fresh install")
    func freshDefaults() {
        let settings = SettingsStore(defaults: ScratchDefaults())
        #expect(settings.shelfPosition == .top)
        #expect(settings.shelfItemCount == 10)
        #expect(settings.sensitiveDetectionEnabled)
        #expect(settings.hideSecretsFromShelf)
        #expect(settings.captureImages)
    }

    @Test("Changes persist across a restart")
    func persists() {
        let defaults = ScratchDefaults()
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
        let settings = SettingsStore(defaults: ScratchDefaults())
        settings.shelfItemCount = input
        #expect(settings.shelfItemCount == expected)
    }

    /// A value written by a future version must degrade to the default rather than failing to
    /// decode and taking the settings window down with it.
    @Test("An unknown stored position falls back to the default")
    func unknownPositionFallsBack() {
        let defaults = ScratchDefaults()
        defaults.set("dynamic-island", forKey: "shelf.position")
        #expect(SettingsStore(defaults: defaults).shelfPosition == .top)
    }

    @Test("Retention policy reflects the settings, with 0 meaning unlimited")
    func buildsRetentionPolicy() {
        let settings = SettingsStore(defaults: ScratchDefaults())
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
        let settings = SettingsStore(defaults: ScratchDefaults())
        settings.hideSecretsFromShelf = false
        #expect(!settings.hideSecretsFromShelf)
    }
}
