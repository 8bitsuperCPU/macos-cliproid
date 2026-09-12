import SwiftUI
import ClipRoidKit
import ClipRoidCore

/// Colours for the shelf, kept in one place.
///
/// The card surface is deliberately **independent of the panel background**. The reported bug was
/// that changing the shelf's background colour also recoloured every clip tile, because the tiles
/// used a semantic material (`.quaternary`) that blends with whatever is behind it. Against a
/// custom opaque panel that made the cards vanish into the background.
///
/// A card is its own surface: always opaque, always a fixed step lighter than the panel, whatever
/// the user picks. Its job is to read as a distinct object sitting *on* the shelf.
enum ShelfPalette {
    // MARK: - On-card colours
    //
    // Fixed, because the card surface is fixed. Text on a card always sits on the same dark grey
    // whatever background the user picks, so it never needs to adapt — and making it adapt would
    // reintroduce the bug where a pale panel made card text unreadable.
    static let cardPrimaryText = Color.white.opacity(0.92)
    static let cardSecondaryText = Color.white.opacity(0.55)
    static let cardTertiaryText = Color.white.opacity(0.38)

    /// Card surface — fixed, opaque, never derived from the panel colour.
    static let card = Color(red: 0.14, green: 0.14, blue: 0.15)
    static let cardHovered = Color(red: 0.20, green: 0.20, blue: 0.22)
    static let cardBorder = Color.white.opacity(0.07)

    /// Chrome that sits directly on the panel.
    static let controlFill = Color.white.opacity(0.08)
    static let controlFillHovered = Color.white.opacity(0.14)

    /// Relative luminance, per WCAG — the standard weighting for how bright a colour *looks*,
    /// rather than a naive average of the channels, which calls pure blue as bright as pure green.
    static func luminance(of hex: String) -> Double {
        guard let c = ColorFormats.components(fromHex: hex) else { return 0 }
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    /// Whether text on the shelf should be light or dark.
    ///
    /// Automatic exists because the alternative is a user picking a pale background and getting an
    /// unreadable shelf, with no obvious way to understand why — which is exactly what happened
    /// with a white background and hard-coded white text.
    @MainActor
    static func usesLightText(_ settings: SettingsStore) -> Bool {
        switch settings.shelfTextStyle {
        case .light: return true
        case .dark: return false
        case .automatic:
            switch settings.shelfBackground {
            case .material: return true
            case .custom: return luminance(of: settings.shelfTintHex) < 0.45
            }
        }
    }

    @MainActor static func primaryText(_ s: SettingsStore) -> Color { text(s, 0.92) }
    @MainActor static func secondaryText(_ s: SettingsStore) -> Color { text(s, 0.55) }
    @MainActor static func tertiaryText(_ s: SettingsStore) -> Color { text(s, 0.38) }

    @MainActor
    private static func text(_ settings: SettingsStore, _ opacity: Double) -> Color {
        usesLightText(settings) ? .white.opacity(opacity) : .black.opacity(opacity)
    }

    /// Chrome contrast has to follow the text, or controls vanish on a pale background too.
    @MainActor
    static func control(_ settings: SettingsStore, hovered: Bool = false) -> Color {
        let base = usesLightText(settings) ? Color.white : Color.black
        return base.opacity(hovered ? 0.16 : 0.09)
    }

    /// The selected chip inverts against the text colour so it always reads as selected.
    @MainActor static func selectedChip(_ s: SettingsStore) -> Color {
        usesLightText(s) ? .white : Color(red: 0.12, green: 0.12, blue: 0.13)
    }

    @MainActor static func selectedChipText(_ s: SettingsStore) -> Color {
        usesLightText(s) ? Color(red: 0.08, green: 0.08, blue: 0.09) : .white
    }

    static let defaultPanel = Color(red: 0.07, green: 0.07, blue: 0.08)

    @MainActor
    static func panel(_ settings: SettingsStore) -> Color {
        switch settings.shelfBackground {
        case .material: defaultPanel
        case .custom: Color(hex: settings.shelfTintHex) ?? defaultPanel
        }
    }
}
