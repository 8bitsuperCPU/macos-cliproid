import Foundation

/// Features that are built but not shipped.
///
/// A flag rather than deleting the code: the implementation stays compiled, tested and ready to
/// switch back on, instead of rotting on a branch or being rewritten from scratch later.
public enum FeatureFlags {
    /// Inline shortcuts — typing `;welcome` and having it expand — and the keystroke observation
    /// they require.
    ///
    /// Hidden and inert for now. Note that this gates the *setting*, not just the UI: the tap
    /// must not come back for a user whose stored preference already has it enabled, and hiding
    /// only the Settings pane would leave exactly those users running it with no way to see it
    /// or turn it off. The stored preference is left untouched, so flipping this back restores
    /// whatever each user had chosen.
    ///
    /// What stays live: `ShortcutMatcher`, `ShortcutExpander`, `KeystrokeObserver`, the store's
    /// shortcut columns and their tests.
    public static let inlineShortcuts = false
}
